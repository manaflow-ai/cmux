/// The Metal source of every ``BackdropShader``, compiled once at run time
/// (``BackdropShaderRenderer``): SwiftPM builds no `.metal` resources for this package, and the
/// source is small enough that compiling it costs a few milliseconds on the render queue.
///
/// Coordinates are drawable pixels with the origin at the bottom left (AppKit's), so the mouse
/// position needs no flip. Every function draws light or dark from `u.dark`.
nonisolated enum BackdropShaderSource {
    /// Bumped whenever a shader's look changes: the posters' file names carry it.
    static let version = 1

    /// The uniforms every fragment reads; ``BackdropShaderUniforms`` is its Swift twin.
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 res;      // drawable size in pixels
        float2 mouse;    // the pointer, smoothed, in pixels from the bottom left
        float time;      // seconds of the shader's own clock
        float energy;    // 0...1, how fast the pointer has been moving
        float dark;      // 1 in the dark appearance
        float pad;
        float4 rings[4]; // a click: xy where, z when (shader time), w 1 while live
    };

    struct VOut { float4 pos [[position]]; };

    vertex VOut wp_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    static float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }

    static float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        const float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = m * p; a *= 0.5; }
        return v;
    }

    static float2 pixel(float4 pos, constant Uniforms& u) { return float2(pos.x, u.res.y - pos.y); }

    // How bright the rings of recent clicks are at p (units of the short side).
    static float rings(float2 p, constant Uniforms& u, float s, float speed, float width) {
        float lit = 0.0;
        for (int i = 0; i < 4; i++) {
            float4 r = u.rings[i];
            float age = u.time - r.z;
            if (r.w < 0.5 || age < 0.0 || age > 5.0) continue;
            float x = length(p - r.xy / s) - age * speed;
            lit += exp(-x * x / (width * width)) * exp(-age * 0.9);
        }
        return lit;
    }

    // Currents: domain-warped ink; the pointer stirs a vortex, faster when it moves.
    fragment float4 wp_currents(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 p = pixel(in.pos, u) / s, m = u.mouse / s, d = p - m;
        float r2 = dot(d, d);
        float swirl = (0.7 + 2.2 * u.energy) * exp(-r2 * 8.0);
        float c = cos(swirl), sn = sin(swirl);
        p = m + float2x2(c, sn, -sn, c) * d;
        float t = u.time * 0.045;
        float2 q = float2(fbm(p * 1.8 + t), fbm(p * 1.8 + float2(5.2, 1.3) - t));
        float2 w = float2(fbm(p * 1.8 + 3.0 * q + float2(1.7, 9.2) + 1.4 * t),
                          fbm(p * 1.8 + 3.0 * q + float2(8.3, 2.8) - 1.2 * t));
        float f = fbm(p * 1.8 + 3.0 * w);
        float vein = clamp(length(q) * length(w) - 0.3, 0.0, 1.0);
        float3 darkInk = mix(float3(0.02, 0.03, 0.08), float3(0.05, 0.24, 0.33), clamp(f * f * 2.2, 0.0, 1.0));
        darkInk = mix(darkInk, float3(0.86, 0.52, 0.32), vein * 0.55);
        float3 lightInk = mix(float3(0.95, 0.93, 0.89), float3(0.52, 0.68, 0.79), clamp(f * f * 2.0, 0.0, 1.0));
        lightInk = mix(lightInk, float3(0.88, 0.50, 0.42), vein * 0.45);
        float3 col = mix(lightInk, darkInk, u.dark);
        float glow = exp(-r2 * 30.0) * (0.04 + 0.10 * u.energy) + rings(pixel(in.pos, u) / s, u, s, 0.45, 0.03) * 0.18;
        col += glow * mix(float3(0.25, 0.35, 0.45), float3(0.55, 0.75, 0.85), u.dark);
        return float4(col, 1.0);
    }

    // The pond's surface height at p: the clicks' rings, the pointer's wake, a slow swell.
    static float pond(float2 p, constant Uniforms& u, float s) {
        float h = 0.07 * fbm(p * 3.0 + float2(u.time * 0.03, -u.time * 0.02));
        for (int i = 0; i < 4; i++) {
            float4 r = u.rings[i];
            float age = u.time - r.z;
            if (r.w < 0.5 || age < 0.0 || age > 6.0) continue;
            float x = length(p - r.xy / s) - age * 0.32;
            h += sin(x * 70.0) * exp(-x * x * 90.0) * exp(-age * 0.6) * 0.5;
        }
        float rm = length(p - u.mouse / s);
        h += u.energy * 0.22 * sin(rm * 80.0 - u.time * 7.0) * exp(-rm * rm * 50.0);
        return h;
    }

    // Ripples: a still pond lit from above; its normal comes from the height's slope.
    fragment float4 wp_ripples(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 p = pixel(in.pos, u) / s;
        float e = 1.5 / s;
        float h = pond(p, u, s);
        float2 g = float2(pond(p + float2(e, 0), u, s) - h, pond(p + float2(0, e), u, s) - h) / e;
        float3 n = normalize(float3(-g * 0.012, 1.0));
        float3 l = normalize(float3(-0.4, 0.5, 0.8));
        float diffuse = clamp(dot(n, l), 0.0, 1.0);
        float spec = pow(clamp(dot(reflect(-l, n), float3(0, 0, 1)), 0.0, 1.0), 40.0);
        float caustic = pow(clamp(1.0 - abs(fbm(p * 6.0 + n.xy * 2.0 + u.time * 0.05) - 0.5) * 3.0, 0.0, 1.0), 6.0);
        float depth = fbm(p * 1.2 - u.time * 0.01);
        float3 darkWater = mix(float3(0.01, 0.05, 0.07), float3(0.03, 0.15, 0.17), depth) * (0.75 + 0.35 * diffuse);
        darkWater += caustic * float3(0.05, 0.16, 0.16) + spec * float3(0.55, 0.70, 0.72);
        float3 lightWater = mix(float3(0.80, 0.90, 0.91), float3(0.62, 0.80, 0.84), depth) * (0.85 + 0.2 * diffuse);
        lightWater += caustic * float3(0.10, 0.12, 0.10) + spec * float3(0.35, 0.35, 0.33);
        return float4(mix(lightWater, darkWater, u.dark), 1.0);
    }

    // One curtain of light: where it hangs (its foot), how it waves, how bright its rays are.
    static float curtain(float2 p, float2 m, float t, float seed, float energy) {
        float dx = p.x - m.x;
        float lean = exp(-dx * dx * 10.0);
        float foot = 0.45 + seed * 0.12 + 0.13 * (fbm(float2(p.x * 1.3 + seed * 7.0, t * 0.12 + seed)) - 0.5) * 2.0;
        foot = mix(foot, m.y - 0.08, lean * 0.35);
        float y = p.y - foot;
        float rays = 0.55 + 0.45 * fbm(float2(p.x * 16.0 + seed * 3.0, t * 0.3));
        float body = y > 0.0 ? exp(-y * (3.2 - lean * 1.2)) : exp(y * 40.0);
        return body * rays * (1.0 + lean * (0.4 + energy));
    }

    // Aurora: three curtains over a sky; the curtain under the pointer dips toward it and brightens.
    fragment float4 wp_aurora(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float vy = px.y / u.res.y;
        float t = u.time;
        float a = curtain(p, m, t, 0.0, u.energy);
        float b = curtain(p + float2(0.7, 0.0), m + float2(0.7, 0.0), t * 1.1, 0.8, u.energy);
        float c = curtain(p + float2(1.9, 0.0), m + float2(1.9, 0.0), t * 0.9, 1.6, u.energy);
        float3 darkSky = mix(float3(0.01, 0.02, 0.05), float3(0.03, 0.03, 0.10), vy);
        float star = step(0.9975, hash21(floor(px / 2.0))) * (0.5 + 0.5 * sin(t * 2.0 + hash21(floor(px / 2.0) + 3.0) * 40.0));
        darkSky += star * 0.6 * (1.0 - a * 0.8);
        float3 darkCol = darkSky + a * float3(0.10, 0.75, 0.45) * 0.55 + b * float3(0.35, 0.25, 0.80) * 0.40
            + c * float3(0.10, 0.55, 0.65) * 0.35;
        float3 lightSky = mix(float3(0.98, 0.90, 0.84), float3(0.80, 0.86, 0.95), vy);
        float3 lightCol = lightSky - a * float3(0.35, 0.05, 0.20) * 0.35 - b * float3(0.10, 0.25, 0.05) * 0.30
            - c * float3(0.30, 0.10, 0.02) * 0.25;
        float3 col = mix(lightCol, darkCol, u.dark);
        col += rings(p, u, s, 0.5, 0.025) * mix(float3(-0.08, -0.04, 0.0), float3(0.10, 0.25, 0.18), u.dark);
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    static float sq(float x) { return x * x; }

    // One glass bubble of radius r at c laid over col: a tinted body, a fresnel rim, a gloss over
    // the top, a hot spot and light gathered in a crescent at the bottom (y is up). e is a pixel.
    static float3 aeroBubble(float3 col, float2 p, float2 c, float r, float3 tint, float e) {
        float2 q = (p - c) / r;
        float d = length(q);
        float3 rim = mix(tint, float3(1.0), 0.35);
        float halo = exp(-max(d - 1.0, 0.0) * 14.0) * 0.10 * (1.0 - smoothstep(1.05, 1.25, d));
        col = 1.0 - (1.0 - col) * (1.0 - rim * halo);
        float cover = 1.0 - smoothstep(1.0 - e / r, 1.0 + e / r, d);
        if (cover <= 0.0) return col;
        float z = sqrt(max(1.0 - d * d, 0.0));
        float edge = 1.0 - z;
        float3 glass = col * mix(float3(1.0), tint, 0.45) * 1.08 + tint * 0.04;
        glass = mix(glass, rim, pow(edge, 3.0) * 0.8);
        float outline = exp(-sq(((1.0 - d) * r / e - 0.9) / (0.9 + r * 0.012 / e)));
        glass = mix(glass, tint * 0.45, outline * 0.3);
        float2 g = float2((q.x + 0.02) / 0.74, (q.y - 0.43) / 0.47);
        float sheen = (1.0 - smoothstep(0.72, 1.0, dot(g, g))) * 0.92 * pow(smoothstep(-0.75, 0.95, g.y), 1.6) * 0.75;
        float hot = exp(-(sq(q.x + 0.3) + sq(q.y - 0.55)) / 0.004);
        float crescent = exp(-sq((d - 0.91) / 0.055)) * (1.0 - smoothstep(-0.95, -0.35, q.y)) * 0.55;
        glass = 1.0 - (1.0 - glass) * (1.0 - clamp(sheen + hot, 0.0, 1.0));
        glass = 1.0 - (1.0 - glass) * (1.0 - mix(tint, float3(1.0), 0.55) * crescent);
        return mix(col, glass, cover);
    }

    // Aero: a glossy sky with swooshes of light and glass bubbles rising through it. Bubbles near
    // the pointer drift aside, the swooshes lean toward it, and a click sends a ring of light out.
    fragment float4 wp_aero(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float e = 1.0 / s;
        float vy = px.y / u.res.y;
        float t = u.time;
        float aspect = u.res.x / s, height = u.res.y / s;
        float3 lightSky = mix(float3(0.93, 0.97, 1.0), mix(float3(0.67, 0.80, 0.94), float3(0.0, 0.50, 0.77),
                              smoothstep(0.45, 1.0, vy)), smoothstep(0.0, 0.55, vy));
        float3 darkSky = mix(float3(0.02, 0.17, 0.28), mix(float3(0.03, 0.20, 0.44), float3(0.01, 0.04, 0.14),
                             smoothstep(0.45, 1.0, vy)), smoothstep(0.0, 0.5, vy));
        float3 col = mix(lightSky, darkSky, u.dark);
        // The sun, high on the left, and its rays.
        float2 sun = float2(0.22 * aspect, height + 0.02);
        float sd = length(p - sun);
        float3 sunTint = mix(float3(1.0, 0.97, 0.90), float3(0.35, 0.80, 0.90), u.dark);
        col += sunTint * (0.50 * exp(-sd * sd * 20.0) + 0.16 * exp(-sd * 2.2)) * mix(1.0, 0.45, u.dark);
        float2 dir = (p - sun) / max(sd, 0.001);
        float ray = pow(vnoise(dir * 6.0 + 50.0 + t * 0.015), 4.0) * 3.0 * exp(-sd * 1.1) * 0.16;
        col = 1.0 - (1.0 - col) * (1.0 - sunTint * clamp(ray, 0.0, 1.0));
        // Three glossy swooshes across the lower half.
        float3 swoosh = mix(float3(1.0), float3(0.55, 0.92, 1.0), u.dark);
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float base = 0.20 + 0.10 * fk - 0.06 * p.x / aspect;
            float lean = exp(-(p.x - m.x) * (p.x - m.x) * 6.0) * (m.y - base) * 0.2 * (0.4 + u.energy);
            float yc = base + 0.07 * sin(1.6 * p.x + t * 0.11 * (1.0 + 0.3 * fk) + fk * 2.1)
                + 0.02 * sin(4.3 * p.x - t * 0.19 + fk) + lean;
            float pinch = 0.5 + 0.5 * sin(2.3 * p.x + fk * 1.7 + t * 0.07);
            float th = (0.065 - 0.016 * fk) * (0.08 + 0.92 * pinch * pinch) + e;
            float d = (p.y - yc) / th;
            float ad = abs(d);
            float body = (1.0 - smoothstep(1.0 - e / th, 1.0 + e / th, ad)) * (0.16 + 0.30 * smoothstep(-1.0, 1.0, d));
            float ew = 1.4 * e / th;
            float lines = exp(-sq((d - 1.0) / ew)) * 0.9 + exp(-sq((d + 1.0) / ew)) * 0.45;
            float a = clamp((body + lines) * (0.9 - 0.15 * fk), 0.0, 1.0);
            col = 1.0 - (1.0 - col) * (1.0 - swoosh * a);
        }
        // Caustic light rippling along the bottom.
        float caustic = pow(clamp(1.0 - abs(fbm(p * float2(3.0, 6.0) + float2(t * 0.05, -t * 0.03)) - 0.5) * 3.0,
                                  0.0, 1.0), 6.0);
        col += caustic * (1.0 - smoothstep(0.0, 0.3, vy)) * mix(float3(0.10, 0.14, 0.14), float3(0.05, 0.18, 0.20), u.dark);
        // Bubbles rising, smallest first; the first is the large one bobbing on the right.
        for (int i = 15; i >= 0; i--) {
            float fi = float(i);
            float h1 = hash21(float2(fi, 1.7)), h2 = hash21(float2(fi, 9.1)), h3 = hash21(float2(fi, 4.3));
            float r = i == 0 ? 0.16 : 0.012 + 0.07 * h2 * h2 * h2;
            float2 c;
            if (i == 0) {
                c = float2(0.72 * aspect, 0.52 * height + 0.02 * sin(t * 0.4));
            } else {
                float span = height + 4.0 * r;
                float rise = fmod(h3 * span + t * (0.015 + 0.03 * (1.0 - h2)), span) - 2.0 * r;
                c = float2((0.3 + 0.7 * h1) * aspect + 0.02 * sin(t * 0.5 + fi * 1.3), rise);
            }
            float2 away = c - m;
            float dist = max(length(away), 0.001);
            c += away / dist * 0.07 * (0.4 + u.energy) * exp(-dist * dist / 0.03) * (i == 0 ? 0.3 : 1.0);
            float3 tint = mix(float3(0.45, 0.88, 1.0), float3(0.78, 0.95, 1.0), h1);
            tint = mix(tint, float3(0.75, 1.0, 0.55), step(0.8, h3) * 0.6);
            col = aeroBubble(col, p, c, r, mix(tint, tint * 0.8 + 0.1, u.dark), e);
        }
        col = 1.0 - (1.0 - col) * (1.0 - clamp(rings(p, u, s, 0.5, 0.02) * 0.35, 0.0, 1.0) * swoosh);
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // Dot Field: a grid of dots the pointer pushes away and the clicks' rings shove outward.
    fragment float4 wp_field(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float gap = max(s / 34.0, 10.0);
        float2 cell = floor(px / gap);
        float reach = gap * 5.0;
        float ink = 0.0;
        float hue = 0.0;
        for (int j = -2; j <= 2; j++) {
            for (int i = -2; i <= 2; i++) {
                float2 id = cell + float2(i, j);
                float2 center = (id + 0.5) * gap;
                float2 away = center - u.mouse;
                float dist = max(length(away), 0.001);
                float push = gap * (1.2 + 1.6 * u.energy) * exp(-dist * dist / (reach * reach));
                float2 dir = away / dist;
                float ring = 0.0;
                for (int k = 0; k < 4; k++) {
                    float4 r = u.rings[k];
                    float age = u.time - r.z;
                    if (r.w < 0.5 || age < 0.0 || age > 4.0) continue;
                    float2 off = center - r.xy;
                    float rd = max(length(off), 0.001);
                    float x = (rd - age * s * 0.5) / (gap * 2.0);
                    float shove = exp(-x * x) * exp(-age * 1.1);
                    center += off / rd * shove * gap * 1.5;
                    ring += shove;
                }
                center += dir * push;
                float breathe = 0.5 + 0.5 * sin(u.time * 0.9 + dot(id, float2(0.31, 0.17)));
                float radius = gap * (0.10 + 0.05 * breathe + 0.10 * exp(-dist * dist / (reach * reach)) + 0.08 * ring);
                float dotInk = smoothstep(radius + 0.8, radius - 0.8, length(px - center));
                if (dotInk > ink) { ink = dotInk; hue = fract(dot(id, float2(0.013, 0.021)) + u.time * 0.01) + ring * 0.2; }
            }
        }
        float3 tint = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
        float3 darkCol = mix(float3(0.035, 0.035, 0.05), mix(float3(0.55, 0.60, 0.70), tint, 0.55), ink);
        float3 lightCol = mix(float3(0.96, 0.95, 0.93), mix(float3(0.30, 0.32, 0.38), tint * 0.7, 0.5), ink);
        return float4(mix(lightCol, darkCol, u.dark), 1.0);
    }
    """#
}

/// The uniforms in ``BackdropShaderSource/source``'s layout: 16-byte aligned, 96 bytes.
nonisolated struct BackdropShaderUniforms: Equatable, Sendable {
    var resolution: SIMD2<Float> = .zero
    var mouse: SIMD2<Float> = .zero
    var time: Float = 0
    var energy: Float = 0
    var dark: Float = 0
    var pad: Float = 0
    var rings: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resolution == rhs.resolution && lhs.mouse == rhs.mouse && lhs.time == rhs.time && lhs.energy == rhs.energy
            && lhs.dark == rhs.dark && lhs.rings.0 == rhs.rings.0 && lhs.rings.1 == rhs.rings.1
            && lhs.rings.2 == rhs.rings.2 && lhs.rings.3 == rhs.rings.3
    }

    /// The rings as an array, in slot order (tests).
    var ringList: [SIMD4<Float>] { [rings.0, rings.1, rings.2, rings.3] }

    /// Puts `ring` in slot `index` (0...3).
    mutating func setRing(_ ring: SIMD4<Float>, at index: Int) {
        switch index & 3 {
        case 0: rings.0 = ring
        case 1: rings.1 = ring
        case 2: rings.2 = ring
        default: rings.3 = ring
        }
    }
}
