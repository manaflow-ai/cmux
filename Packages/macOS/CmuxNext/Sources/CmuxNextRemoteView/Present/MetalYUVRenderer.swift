import CmuxNextCompat
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// The presenter's `CAMetalLayer`, shared by the main actor, which places and
/// scales it, and the render actor, which sizes and draws its drawables.
nonisolated struct SharedMetalLayer: @unchecked Sendable { // crash-allow: main and the render queue touch disjoint layer state: main sets frame, isHidden, contentsGravity, backgroundColor, filters and contentsScale, and device, pixel format and the first colorspace before the first draw; the render queue only sets drawableSize and colorspace (in its own CATransaction) and calls nextDrawable. Core Animation locks the layer in each property accessor
    let layer: CAMetalLayer

    init(_ layer: CAMetalLayer) {
        self.layer = layer
    }
}

/// Draws one NV12 frame into a `CAMetalLayer` drawable with a YUV to RGB
/// shader (BT.709, 1:1 pixels), or one four-channel RGB frame with a copy shader. The actor runs on its own serial render
/// queue, off the main thread and off the cooperative pool: `nextDrawable`
/// may wait there for one of the two drawables. Its texture cache and the
/// layer's drawable size are touched only there.
///
/// The shaders compile on the render queue at the first draw, never on the
/// thread that makes the renderer (a pane's init on main), as Chrome builds
/// its pipelines on the GPU thread. The layer's `colorspace` follows each
/// frame's colour tags, so Core Animation colour-matches the drawable to the
/// display as it does a tagged IOSurface.
///
/// The render queue is on threading-model.md's closed user-interactive list: the remote desktop's frames are a
/// compositor-class motion path, which Chrome runs at `ThreadType::kDisplayCritical`
/// (base/threading/platform_thread.h; user-interactive in base/threading/platform_thread_apple.mm).
actor MetalYUVRenderer {
    // qos-allow: closed list (threading-model.md): the remote view's frames wait on this queue, Chrome's kDisplayCritical
    private nonisolated let queue = DispatchQueue.checkedSerial(label: "cmux.remote-view.render", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let shared: SharedMetalLayer
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    /// Built at the first draw, on the render queue (once: nil when the shaders do not build).
    private lazy var pipelines: Pipelines? = Self.makePipelines(device: device)
    /// The colour tags of the last frame drawn (the layer's colorspace was set from them).
    private var colorTags: CFDictionary?

    /// The YUV and the RGB pipeline, from one compiled library.
    private nonisolated struct Pipelines {
        let yuv: any MTLRenderPipelineState
        let rgb: any MTLRenderPipelineState
    }

    /// Nil where Metal is missing. Compiles nothing: the pipelines are built at the first draw.
    init?(layer shared: SharedMetalLayer) {
        guard let device = shared.layer.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        // SAFETY: Core Video writes one +1 cache to the local `cache`, live for the call;
        // the nil attribute dictionaries are not read.
        guard unsafe CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        shared.layer.device = device
        // Untagged frames are sRGB; a nil colorspace would show the samples with no colour matching.
        shared.layer.colorspace = Self.sRGB
        self.shared = shared
        self.device = device
        self.commandQueue = commandQueue
        textureCache = cache
    }

    /// Takes the mailbox's newest frame, draws it and records it shown in the mailbox in this turn
    /// (so records keep draw order). Returns the record when the frame is on its way to the screen,
    /// nil when there was none or it could not be drawn.
    func drawNewest(from mailbox: LatestFrameMailbox<RemoteDecodedFrame>) -> LatestFrameMailbox<RemoteDecodedFrame>.Shown? {
        guard let frame = mailbox.take(), render(frame) else { return nil }
        return mailbox.recordShown(frame)
    }

    /// Draws `frame` and presents it at the next refresh. Returns false when
    /// the frame could not be drawn (no drawable within the layer's timeout,
    /// or a plane that does not map to a texture).
    private func render(_ frame: RemoteDecodedFrame) -> Bool {
        let buffer = frame.pixelBuffer
        guard let pipelines else { return false }
        if CVPixelBufferGetPlaneCount(buffer) == 2 {
            guard let luma = texture(buffer, plane: 0, format: .r8Unorm),
                  let chroma = texture(buffer, plane: 1, format: .rg8Unorm) else { return false }
            let fullRange: Float = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
            return draw(buffer, pipeline: pipelines.yuv, textures: [luma, chroma], fullRange: fullRange)
        }
        // A four-channel 8-bit RGB frame (a simulator's framebuffer, a host that sends RGB): one texture, a copy shader.
        guard let format = Self.rgbTextureFormat(CVPixelBufferGetPixelFormatType(buffer)),
              let rgb = texture(buffer, plane: 0, format: format) else { return false }
        return draw(buffer, pipeline: pipelines.rgb, textures: [rgb], fullRange: 0)
    }

    /// The Metal format that reads a one-plane buffer of `pixelFormat`, nil for one this renderer
    /// does not draw. Only 8-bit, gamma-encoded RGB: the copy shader writes the samples unchanged into
    /// an 8-bit drawable, so a 10-bit or half-float (extended-linear) buffer would lose its range and
    /// transfer. Those take the still-frame path, which Core Animation colour-matches.
    nonisolated static func rgbTextureFormat(_ pixelFormat: OSType) -> MTLPixelFormat? {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA: .bgra8Unorm
        case kCVPixelFormatType_32RGBA: .rgba8Unorm
        default: nil
        }
    }

    nonisolated static var sRGB: CGColorSpace? { CGColorSpace(name: CGColorSpace.sRGB) }

    /// The colour space `buffer`'s samples are in: its own, else the one its colour tags (`tags`, its
    /// propagated attachments: primaries, transfer function, ICC profile) name, else sRGB.
    nonisolated static func colorSpace(of buffer: CVPixelBuffer, tags: CFDictionary?) -> CGColorSpace? {
        if let own = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() { return own }
        if let tags, let named = CVImageBufferCreateColorSpaceFromAttachments(tags)?.takeRetainedValue() { return named }
        return sRGB
    }

    /// Whether this renderer draws buffers of `pixelFormat`: NV12 (video or full range) or one-plane RGB.
    nonisolated static func draws(pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || rgbTextureFormat(pixelFormat) != nil
    }

    /// Draws `textures` (fragment textures 0, 1, ...) with `pipeline` into the next drawable, sized
    /// to `buffer`, and presents it at the next refresh.
    private func draw(_ buffer: CVPixelBuffer, pipeline: any MTLRenderPipelineState, textures: [CVMetalTexture],
                      fullRange: Float) -> Bool {
        let layer = shared.layer
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        // The frame's colour tags; the space is made again only when they change (a stream keeps them).
        let tags = CVBufferCopyAttachments(buffer, .shouldPropagate)
        let tagsChanged = !Self.same(tags, colorTags)
        if layer.drawableSize != size || tagsChanged {
            // An explicit transaction: this thread has no run loop to commit an implicit one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if layer.drawableSize != size { layer.drawableSize = size }
            if tagsChanged {
                colorTags = tags
                layer.colorspace = Self.colorSpace(of: buffer, tags: tags)
            }
            CATransaction.commit()
        }
        guard let drawable = layer.nextDrawable(),
              let commands = commandQueue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let metalTextures = textures.compactMap { CVMetalTextureGetTexture($0) }
        guard metalTextures.count == textures.count,
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in metalTextures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        var range = fullRange
        // SAFETY: Metal copies length (one Float) bytes from the local `range` during the call.
        unsafe encoder.setFragmentBytes(&range, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // The cache textures must outlive the GPU's reads: the completed handler holds them.
        let retained = textures.map { RemoteFrameBuffer($0) }
        commands.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        commands.present(drawable)
        commands.commit()
        return true
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        // A non-planar buffer has no planes: its one image is the whole buffer.
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        // SAFETY: Core Video writes one +1 texture to the local `texture`, live for the call.
        let status = unsafe CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format, width, height, plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    private nonisolated static func same(_ a: CFDictionary?, _ b: CFDictionary?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): CFEqual(a, b)
        default: false
        }
    }

    /// Compiles the shader source once and builds the YUV and the RGB pipeline from that library.
    private nonisolated static func makePipelines(device: any MTLDevice) -> Pipelines? {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "rv_vertex"),
              let yuv = makePipeline(device: device, vertex: vertex, fragment: library.makeFunction(name: "rv_fragment")),
              let rgb = makePipeline(device: device, vertex: vertex, fragment: library.makeFunction(name: "rv_fragment_rgb"))
        else { return nil }
        return Pipelines(yuv: yuv, rgb: rgb)
    }

    private nonisolated static func makePipeline(device: any MTLDevice, vertex: any MTLFunction,
                                                 fragment: (any MTLFunction)?) -> (any MTLRenderPipelineState)? {
        guard let fragment else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// A full-screen triangle; luma sampled nearest (1:1 pixels keep text
    /// exact), chroma linear (it is half resolution).
    nonisolated static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut rv_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }
    fragment float4 rv_fragment(VOut in [[stage_in]],
                                texture2d<float> luma [[texture(0)]],
                                texture2d<float> chroma [[texture(1)]],
                                constant float &fullRange [[buffer(0)]]) {
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        constexpr sampler smooth(filter::linear, address::clamp_to_edge);
        float y = luma.sample(nearest, in.uv).r;
        float2 c = chroma.sample(smooth, in.uv).rg;
        if (fullRange > 0.5) {
            c -= 0.5;
        } else {
            y = (y - 16.0 / 255.0) * (255.0 / 219.0);
            c = (c - 128.0 / 255.0) * (255.0 / 224.0);
        }
        float3 rgb = float3(y + 1.5748 * c.y,
                            y - 0.1873 * c.x - 0.4681 * c.y,
                            y + 1.8556 * c.x);
        return float4(saturate(rgb), 1.0);
    }
    fragment float4 rv_fragment_rgb(VOut in [[stage_in]], texture2d<float> rgb [[texture(0)]]) {
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        return float4(rgb.sample(nearest, in.uv).rgb, 1.0);
    }
    """
}
