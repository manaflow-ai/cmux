import CmuxNextCompat
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// The presenter's `CAMetalLayer`, shared by the main actor, which places and
/// scales it, and the render actor, which sizes and draws its drawables.
nonisolated struct SharedMetalLayer: @unchecked Sendable { // crash-allow: main and the render queue touch disjoint layer state: main sets frame, isHidden, contentsGravity, filters and contentsScale, and device and pixel format before the first draw; the render queue only sets drawableSize (in its own CATransaction) and calls nextDrawable. Core Animation locks the layer in each property accessor
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
/// The render queue is on threading-model.md's closed user-interactive list: the remote desktop's frames are a
/// compositor-class motion path, which Chrome runs at `ThreadType::kDisplayCritical`
/// (base/threading/platform_thread.h; user-interactive in base/threading/platform_thread_apple.mm).
actor MetalYUVRenderer {
    // qos-allow: closed list (threading-model.md): the remote view's frames wait on this queue, Chrome's kDisplayCritical
    private nonisolated let queue = DispatchQueue.checkedSerial(label: "cmux.remote-view.render", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let shared: SharedMetalLayer
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let rgbPipeline: any MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    init?(layer shared: SharedMetalLayer) {
        guard let device = shared.layer.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device: device),
              let rgbPipeline = Self.makePipeline(device: device, fragment: "rv_fragment_rgb") else { return nil }
        var cache: CVMetalTextureCache?
        // SAFETY: Core Video writes one +1 cache to the local `cache`, live for the call;
        // the nil attribute dictionaries are not read.
        guard unsafe CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        shared.layer.device = device
        self.shared = shared
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.rgbPipeline = rgbPipeline
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
        if CVPixelBufferGetPlaneCount(buffer) == 2 {
            guard let luma = texture(buffer, plane: 0, format: .r8Unorm),
                  let chroma = texture(buffer, plane: 1, format: .rg8Unorm) else { return false }
            let fullRange: Float = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
            return draw(buffer, pipeline: pipeline, textures: [luma, chroma], fullRange: fullRange)
        }
        // A four-channel RGB frame (a simulator's framebuffer, a host that sends RGB): one texture, a copy shader.
        guard let format = Self.rgbTextureFormat(CVPixelBufferGetPixelFormatType(buffer)),
              let rgb = texture(buffer, plane: 0, format: format) else { return false }
        return draw(buffer, pipeline: rgbPipeline, textures: [rgb], fullRange: 0)
    }

    /// The Metal format that reads a one-plane buffer of `pixelFormat`, nil for one this renderer
    /// does not draw.
    nonisolated static func rgbTextureFormat(_ pixelFormat: OSType) -> MTLPixelFormat? {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA: .bgra8Unorm
        case kCVPixelFormatType_32RGBA: .rgba8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked: .bgr10a2Unorm
        case kCVPixelFormatType_64RGBAHalf: .rgba16Float
        default: nil
        }
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
        if layer.drawableSize != size {
            // An explicit transaction: this thread has no run loop to commit an implicit one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.drawableSize = size
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

    nonisolated static func makePipeline(device: any MTLDevice, fragment name: String = "rv_fragment") -> (any MTLRenderPipelineState)? {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "rv_vertex"),
              let fragment = library.makeFunction(name: name) else { return nil }
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
