import CoreGraphics
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Draws one NV12 frame into a `CAMetalLayer` drawable with a YUV to RGB
/// shader (1:1 pixels) in the frame's own colour: the YCbCr matrix the decoder
/// attached (BT.709, BT.601, BT.2020; untagged is BT.601, what every untagged
/// host sends), the range of its pixel format, and the layer colour-matched
/// from its primaries (sRGB, Display P3). Every call runs on `queue`, a serial
/// render queue off the main thread; `nextDrawable` may wait there for one of
/// the two drawables, never on the main thread.
nonisolated final class MetalYUVRenderer: @unchecked Sendable {
    // @unchecked: every mutable member (texture cache, the layer's drawable
    // size and colour space, `primaries`) is touched only on `queue`; the rest
    // is immutable after init.
    let queue = DispatchQueue(label: "cmux.remote-view.render", qos: .userInteractive)
    private let layer: CAMetalLayer
    let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    /// The primaries the layer's colour space was set for (nil: not set yet).
    private var primaries: String?

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
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let framePrimaries = Self.attachment(buffer, kCVImageBufferColorPrimariesKey) ?? ""
        if layer.drawableSize != size || primaries != framePrimaries {
            // An explicit transaction: this thread has no run loop to commit an implicit one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.drawableSize = size
            if primaries != framePrimaries {
                primaries = framePrimaries
                layer.colorspace = CGColorSpace(name: Self.colorSpaceName(primaries: framePrimaries))
            }
            CATransaction.commit()
        }
        guard let drawable = layer.nextDrawable(),
              let commands = commandQueue.makeCommandBuffer(),
              encodeDraw(buffer, into: drawable.texture, commands: commands) else { return false }
        if let onPresented = frame.onPresented {
            // The viewer's Present stage: when the picture reached the glass (host time in
            // seconds, the `DispatchTime` uptime base); 0 when the drawable was never shown.
            drawable.addPresentedHandler { shown in
                let at = shown.presentedTime
                if at > 0 { onPresented(UInt64(at * 1_000_000)) }
            }
        }
        commands.present(drawable)
        commands.commit()
        return true
    }

    /// Encodes the YUV to RGB draw of `buffer` into `target` (BGRA8, the buffer's size) on
    /// `commands`; the caller presents or reads back and commits. False when a plane does not
    /// map to a texture.
    func encodeDraw(_ buffer: CVPixelBuffer, into target: any MTLTexture, commands: any MTLCommandBuffer) -> Bool {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let luma = texture(buffer, plane: 0, format: .r8Unorm),
              let chroma = texture(buffer, plane: 1, format: .rg8Unorm) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma) else { return false }
        var conversion = Self.conversion(for: buffer)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentBytes(&conversion, length: MemoryLayout<SIMD8<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // The cache textures must outlive the GPU's reads.
        let retained = RetainedTextures(luma: luma, chroma: chroma)
        commands.addCompletedHandler { _ in retained.release() }
        return true
    }

    /// The shader's YCbCr to RGB constants for `buffer`: luma offset and scale, chroma scale,
    /// then Cr to R, Cb to G, Cr to G and Cb to B (`rv_fragment`'s `k`).
    static func conversion(for buffer: CVPixelBuffer) -> SIMD8<Float> {
        let fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let matrix = attachment(buffer, kCVImageBufferYCbCrMatrixKey)
        let (kr, kb): (Float, Float) =
            if matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { (0.2126, 0.0722) }
            else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { (0.2627, 0.0593) }
            else { (0.299, 0.114) }
        let kg = 1 - kr - kb
        return SIMD8(
            fullRange ? 0 : 16 / 255, fullRange ? 1 : 255 / 219, fullRange ? 1 : 255 / 224,
            2 * (1 - kr), 2 * kb * (1 - kb) / kg, 2 * kr * (1 - kr) / kg, 2 * (1 - kb), 0)
    }

    /// The layer's colour space for a stream's primaries: Display P3 for P3 D65, BT.2020 for
    /// BT.2020, else sRGB (BT.709 primaries, which every untagged host sends).
    static func colorSpaceName(primaries: String) -> CFString {
        if primaries == kCVImageBufferColorPrimaries_P3_D65 as String { CGColorSpace.displayP3 }
        else if primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String { CGColorSpace.itur_2020_sRGBGamma }
        else { CGColorSpace.sRGB }
    }

    static func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
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
                                constant float *k [[buffer(0)]]) {
        // k: luma offset, luma scale, chroma scale, Cr to R, Cb to G, Cr to G, Cb to B.
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        constexpr sampler smooth(filter::linear, address::clamp_to_edge);
        float y = (luma.sample(nearest, in.uv).r - k[0]) * k[1];
        float2 c = (chroma.sample(smooth, in.uv).rg - 128.0 / 255.0) * k[2];
        float3 rgb = float3(y + k[3] * c.y,
                            y - k[4] * c.x - k[5] * c.y,
                            y + k[6] * c.x);
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
