import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Draws one NV12 frame into a `CAMetalLayer` drawable with a YUV to RGB
/// shader (BT.709, 1:1 pixels). Every call runs on `queue`, a serial render
/// queue off the main thread; `nextDrawable` may wait there for one of the
/// two drawables, never on the main thread.
nonisolated final class MetalYUVRenderer: @unchecked Sendable {
    // @unchecked: every mutable member (texture cache, the layer's drawable
    // size) is touched only on `queue`; the rest is immutable after init.
    let queue = DispatchQueue(label: "cmux.remote-view.render", qos: .userInteractive)
    private let layer: CAMetalLayer
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    init?(layer: CAMetalLayer) {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device: device) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        layer.device = device
        self.layer = layer
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        textureCache = cache
    }

    /// Draws `frame` and presents it at the next refresh. Returns false when
    /// the frame could not be drawn (no drawable within the layer's timeout,
    /// or a plane that does not map to a texture).
    func render(_ frame: RemoteDecodedFrame) -> Bool {
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
        encoder.setFragmentBytes(&fullRange, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // The cache textures must outlive the GPU's reads.
        let retained = RetainedTextures(luma: luma, chroma: chroma)
        commands.addCompletedHandler { _ in retained.release() }
        commands.present(drawable)
        commands.commit()
        return true
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    static func makePipeline(device: any MTLDevice) -> (any MTLRenderPipelineState)? {
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
    static let shaderSource = """
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

/// Keeps the cache textures alive until the command buffer completes.
private nonisolated final class RetainedTextures: @unchecked Sendable {
    // @unchecked: written once at init, cleared once by the completion handler.
    private var textures: [CVMetalTexture]

    init(luma: CVMetalTexture, chroma: CVMetalTexture) {
        textures = [luma, chroma]
    }

    func release() {
        textures.removeAll()
    }
}
