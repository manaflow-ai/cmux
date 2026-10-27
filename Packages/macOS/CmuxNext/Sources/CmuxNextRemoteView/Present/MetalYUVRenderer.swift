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
/// shader (BT.709, 1:1 pixels). The actor runs on its own serial render
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
    private let textureCache: CVMetalTextureCache

    init?(layer shared: SharedMetalLayer) {
        guard let device = shared.layer.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device: device) else { return nil }
        var cache: CVMetalTextureCache?
        // SAFETY: Core Video writes one +1 cache to the local `cache`, live for the call;
        // the nil attribute dictionaries are not read.
        guard unsafe CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        shared.layer.device = device
        self.shared = shared
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        textureCache = cache
    }

    /// Takes the mailbox's newest frame and draws it. Returns the frame when
    /// it is on its way to the screen, nil when there was none or it could
    /// not be drawn.
    func drawNewest(from mailbox: LatestFrameMailbox<RemoteDecodedFrame>) -> RemoteDecodedFrame? {
        guard let frame = mailbox.take(), render(frame) else { return nil }
        return frame
    }

    /// Draws `frame` and presents it at the next refresh. Returns false when
    /// the frame could not be drawn (no drawable within the layer's timeout,
    /// or a plane that does not map to a texture).
    private func render(_ frame: RemoteDecodedFrame) -> Bool {
        let layer = shared.layer
        let buffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let luma = texture(buffer, plane: 0, format: .r8Unorm),
              let chroma = texture(buffer, plane: 1, format: .rg8Unorm) else { return false }
        let size = CGSize(width: width, height: height)
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
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma) else { return false }
        var fullRange: Float = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        // SAFETY: Metal copies length (one Float) bytes from the local `fullRange` during the call.
        unsafe encoder.setFragmentBytes(&fullRange, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // The cache textures must outlive the GPU's reads: the completed handler holds them.
        let retained = [RemoteFrameBuffer(luma), RemoteFrameBuffer(chroma)]
        commands.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        commands.present(drawable)
        commands.commit()
        return true
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        // SAFETY: Core Video writes one +1 texture to the local `texture`, live for the call.
        let status = unsafe CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    nonisolated static func makePipeline(device: any MTLDevice) -> (any MTLRenderPipelineState)? {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "rv_vertex"),
              let fragment = library.makeFunction(name: "rv_fragment") else { return nil }
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
    """
}
