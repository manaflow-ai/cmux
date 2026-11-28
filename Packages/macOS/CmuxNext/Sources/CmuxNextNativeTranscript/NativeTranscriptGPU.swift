#if canImport(CCmuxNativeTranscriptFFI)
import Foundation
import Metal

/// The native transcript's GPU (RFD 0121, app-perf.md section 6): the default device, one command queue, the one
/// pipeline that draws every `CmuxNtQuad` kind in one instanced draw, its sampler and a 1x1 clear texture for the
/// rich-row slots that hold nothing. Made on the render thread when a transcript opens (the shader compiles there,
/// never on main); immutable after.
// crash-allow: immutable after init; MTLDevice, MTLCommandQueue, MTLRenderPipelineState and MTLSamplerState are documented thread-safe, and the clear texture is written once, in init, before it is shared.
nonisolated final class NativeTranscriptGPU: @unchecked Sendable {
    /// Rich-row textures bound per draw (fragment texture indices 1...richSlots); slot `richSlots - 1` is the
    /// clear texture a quad whose texture is not resident samples.
    static let richSlots = 31
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let sampler: any MTLSamplerState
    let clear: any MTLTexture

    static func make(pixelFormat: MTLPixelFormat) -> NativeTranscriptGPU? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "nt_vertex"), let fragment = library.makeFunction(name: "nt_fragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "native transcript quads"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let color = descriptor.colorAttachments[0] else { return nil }
        color.pixelFormat = pixelFormat
        // Premultiplied alpha: the fragment returns premultiplied color for every kind.
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        let clearDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        clearDescriptor.usage = .shaderRead
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let clear = device.makeTexture(descriptor: clearDescriptor) else { return nil }
        var zero: UInt32 = 0
        clear.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        return NativeTranscriptGPU(device: device, queue: queue, pipeline: pipeline, sampler: sampler, clear: clear)
    }

    /// The one shader pair. The instance buffer is the scene's `CmuxNtQuad` array as written (48 bytes each,
    /// points from the viewport's top-left); the host rewrites a texture quad's `texture_id` to its bound slot
    /// before the draw. Four vertices per instance as a triangle strip.
    static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Quad { float4 rect; float4 uv; uint color; uint kind; uint slot; uint pad; };
        struct Out { float4 position [[position]]; float2 uv; float4 color; uint kind [[flat]]; uint slot [[flat]]; };

        vertex Out nt_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
            Quad q = quads[iid];
            float2 corner = float2(float(vid & 1u), float(vid >> 1u));
            float2 p = q.rect.xy + corner * q.rect.zw;
            Out o;
            o.position = float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
            o.uv = mix(q.uv.xy, q.uv.zw, corner);
            o.color = float4(float((q.color >> 24) & 255u), float((q.color >> 16) & 255u),
                             float((q.color >> 8) & 255u), float(q.color & 255u)) / 255.0;
            o.kind = q.kind;
            o.slot = q.slot;
            return o;
        }

        fragment float4 nt_fragment(Out in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                    array<texture2d<float>, \(richSlots)> rich [[texture(1)]],
                                    sampler s [[sampler(0)]]) {
            if (in.kind == 0u) {
                float a = atlas.sample(s, in.uv).r * in.color.a;
                return float4(in.color.rgb * a, a);
            }
            if (in.kind == 1u) {
                return float4(in.color.rgb * in.color.a, in.color.a);
            }
            return rich[min(in.slot, \(richSlots - 1)u)].sample(s, in.uv);
        }
    """

    private init(device: any MTLDevice, queue: any MTLCommandQueue, pipeline: any MTLRenderPipelineState,
                 sampler: any MTLSamplerState, clear: any MTLTexture) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.clear = clear
    }
}
#endif
