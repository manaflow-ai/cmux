#include <metal_stdlib>
using namespace metal;

struct CanvasVertex {
    float2 position;
    float4 color;
};

struct CanvasRasterVertex {
    float4 position [[position]];
    float4 color;
};

struct CanvasTextureVertex {
    float2 position;
    float2 texCoord;
};

struct CanvasTextureRasterVertex {
    float4 position [[position]];
    float2 texCoord;
};

vertex CanvasRasterVertex cmux_canvas_vertex(
    uint vertexID [[vertex_id]],
    const device CanvasVertex *vertices [[buffer(0)]],
    constant float2 &viewport [[buffer(1)]]
) {
    CanvasVertex input = vertices[vertexID];
    float2 safeViewport = max(viewport, float2(1.0, 1.0));
    float2 ndc = float2(
        (input.position.x / safeViewport.x) * 2.0 - 1.0,
        1.0 - (input.position.y / safeViewport.y) * 2.0
    );
    CanvasRasterVertex output;
    output.position = float4(ndc, 0.0, 1.0);
    output.color = input.color;
    return output;
}

fragment float4 cmux_canvas_fragment(CanvasRasterVertex input [[stage_in]]) {
    return input.color;
}

vertex CanvasTextureRasterVertex cmux_canvas_texture_vertex(
    uint vertexID [[vertex_id]],
    const device CanvasTextureVertex *vertices [[buffer(0)]],
    constant float2 &viewport [[buffer(1)]]
) {
    CanvasTextureVertex input = vertices[vertexID];
    float2 safeViewport = max(viewport, float2(1.0, 1.0));
    float2 ndc = float2(
        (input.position.x / safeViewport.x) * 2.0 - 1.0,
        1.0 - (input.position.y / safeViewport.y) * 2.0
    );
    CanvasTextureRasterVertex output;
    output.position = float4(ndc, 0.0, 1.0);
    output.texCoord = input.texCoord;
    return output;
}

fragment float4 cmux_canvas_texture_fragment(
    CanvasTextureRasterVertex input [[stage_in]],
    texture2d<float> surfaceTexture [[texture(0)]]
) {
    constexpr sampler surfaceSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return surfaceTexture.sample(surfaceSampler, input.texCoord);
}

struct CanvasIOSurfaceVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex CanvasIOSurfaceVertexOut canvas_iosurface_vertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    constexpr float2 coords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    CanvasIOSurfaceVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = coords[vertexID];
    return out;
}

fragment float4 canvas_iosurface_fragment(
    CanvasIOSurfaceVertexOut in [[stage_in]],
    texture2d<float> surfaceTexture [[texture(0)]]
) {
    constexpr sampler surfaceSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return surfaceTexture.sample(surfaceSampler, in.texCoord);
}
