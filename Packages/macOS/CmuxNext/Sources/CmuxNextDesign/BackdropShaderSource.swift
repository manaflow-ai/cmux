/// The Metal source of every ``BackdropShader``, compiled once at run time
/// (``BackdropShaderRenderer``): SwiftPM builds no `.metal` resources for this package, and the
/// source is small enough that compiling it costs a few milliseconds on the render queue.
///
/// Coordinates are drawable pixels with the origin at the bottom left (AppKit's), so the mouse
/// position needs no flip. Every function draws light or dark from `u.dark`.
nonisolated enum BackdropShaderSource {
    /// Bumped whenever a shader's look changes: the posters' file names carry it.
    static let version = 2

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

    static float2 hash22(float2 p) { return float2(hash21(p), hash21(p + float2(17.31, 41.07))); }

    // Mesh: soft mesh-gradient blobs, colors blended by Gaussian radial-basis weights (Shepard's
    // inverse-distance interpolation, 1968, with a Gaussian kernel); every blob leans to the pointer.
    fragment float4 wp_mesh(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s, aspect = u.res / s;
        float t = u.time * 0.05;
        float3 acc = float3(0.0);
        float total = 0.0;
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float2 c = aspect * (0.5 + 0.38 * float2(sin(t * (0.7 + 0.13 * fi) + fi * 2.1), cos(t * (0.6 + 0.11 * fi) + fi * 1.7)));
            float2 toPointer = m - c;
            c += toPointer * (0.16 + 0.12 * u.energy) * exp(-dot(toPointer, toPointer) * 1.5);
            float2 d = p - c;
            float w = exp(-dot(d, d) * 3.2) + 0.0001;
            float3 phase = fi * 0.19 + float3(0.0, 0.33, 0.67);
            float3 lightCol = 0.83 + 0.13 * cos(6.28318 * (phase + 0.05));
            float3 darkCol = 0.13 + 0.10 * cos(6.28318 * (phase + 0.55));
            acc += w * mix(lightCol, darkCol, u.dark);
            total += w;
        }
        float3 col = acc / total;
        float2 d = p - m;
        float lift = exp(-dot(d, d) * 18.0) * (0.03 + 0.05 * u.energy) + rings(p, u, s, 0.4, 0.05) * 0.06;
        col += lift * mix(float3(1.0, 0.98, 0.95), float3(0.55, 0.60, 0.75), u.dark);
        col += (hash21(px) - 0.5) / 255.0; // dither: no bands in the soft gradient
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // Contours: topographic isolines of fbm (Perlin 1985 noise summed in octaves); the pointer
    // raises a hill and a click sends a ring of swell across the map.
    fragment float4 wp_contours(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 p = pixel(in.pos, u) / s, d = p - u.mouse / s;
        float h = fbm(p * 1.9 + float2(u.time * 0.012, -u.time * 0.009));
        h += (0.22 + 0.12 * u.energy) * exp(-dot(d, d) * 14.0);
        h += rings(p, u, s, 0.35, 0.05) * 0.04;
        float f = h * 14.0;
        float g = abs(fract(f - 0.5) - 0.5) / max(fwidth(f), 0.0001);
        float major = step(fract(floor(f + 0.5) * 0.2 + 0.01), 0.1);
        float line = (1.0 - min(g / (1.0 + major * 0.8), 1.0)) * (0.55 + 0.45 * major);
        float3 lightCol = mix(float3(0.96, 0.95, 0.91), float3(0.90, 0.93, 0.92), h);
        lightCol = mix(lightCol, float3(0.42, 0.48, 0.52), line * 0.7);
        float3 darkCol = mix(float3(0.035, 0.045, 0.06), float3(0.05, 0.08, 0.10), h);
        darkCol = mix(darkCol, float3(0.30, 0.62, 0.66), line * 0.75);
        return float4(mix(lightCol, darkCol, u.dark), 1.0);
    }

    // Lava: metaballs (Blinn 1982, "A Generalization of Algebraic Surface Drawing"): six slow
    // blobs rise and sink like a lava lamp; the pointer is one more ball.
    fragment float4 wp_lava(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 p = pixel(in.pos, u) / s, aspect = u.res / s;
        float t = u.time;
        float field = 0.0;
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float2 c = float2(aspect.x * (0.12 + 0.76 * hash21(float2(fi, 3.0))) + 0.06 * sin(t * 0.21 + fi * 1.9),
                              aspect.y * (0.5 + 0.42 * sin(t * (0.07 + 0.025 * fi) + fi * 1.3)));
            float r = 0.08 + 0.06 * hash21(float2(fi, 9.0));
            float2 d = p - c;
            field += r * r / (dot(d, d) + 0.0001);
        }
        float2 dm = p - u.mouse / s;
        float pr = 0.07 * (1.0 + 0.4 * u.energy);
        field += pr * pr / (dot(dm, dm) + 0.0001);
        field += rings(p, u, s, 0.4, 0.03) * 0.5;
        float inside = smoothstep(0.92, 1.08, field);
        float rim = smoothstep(0.75, 1.0, field) * (1.0 - smoothstep(1.0, 1.6, field));
        float core = clamp((field - 1.0) * 0.25, 0.0, 1.0);
        float vy = p.y / aspect.y;
        float3 lightBg = mix(float3(0.98, 0.94, 0.89), float3(0.95, 0.92, 0.94), vy);
        float3 lightBlob = mix(float3(0.98, 0.70, 0.55), float3(0.99, 0.82, 0.62), core);
        float3 lightCol = mix(lightBg, lightBlob, inside) - rim * 0.04;
        float3 darkBg = mix(float3(0.06, 0.03, 0.06), float3(0.03, 0.03, 0.07), vy);
        float3 darkBlob = mix(float3(0.62, 0.16, 0.10), float3(0.95, 0.45, 0.18), core);
        float3 darkCol = mix(darkBg, darkBlob, inside) + rim * float3(0.10, 0.03, 0.02);
        return float4(clamp(mix(lightCol, darkCol, u.dark), 0.0, 1.0), 1.0);
    }

    // Caustics: underwater light on sand, the iterated-trig caustic pattern (joltz0r, Shadertoy
    // 2013); the pointer is a lens that gathers the light and a click ripples the surface.
    fragment float4 wp_caustics(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, d = p - u.mouse / s;
        float lens = exp(-dot(d, d) * 9.0);
        p -= d * lens * (0.25 + 0.2 * u.energy);
        p += rings(p, u, s, 0.35, 0.04) * 0.02;
        float t = u.time * 0.35 + 23.0;
        float2 q = p * 5.5 - 250.0;
        float2 i = q;
        float c = 1.0;
        const float inten = 0.005;
        for (int n = 0; n < 4; n++) {
            float tt = t * (1.0 - 3.5 / float(n + 1));
            i = q + float2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
            c += 1.0 / length(float2(q.x / (sin(i.x + tt) / inten), q.y / (cos(i.y + tt) / inten)));
        }
        c /= 4.0;
        c = 1.17 - pow(c, 1.4);
        float light = clamp(pow(abs(c), 8.0), 0.0, 1.0) * (1.0 + lens * 0.8);
        float sand = fbm(px / s * 9.0) * 0.6 + hash21(floor(px)) * 0.4;
        float3 lightCol = mix(float3(0.88, 0.85, 0.76), float3(0.95, 0.92, 0.84), sand);
        lightCol = mix(lightCol, float3(0.80, 0.90, 0.92), 0.35) + light * float3(0.14, 0.15, 0.12);
        float3 darkCol = mix(float3(0.02, 0.06, 0.09), float3(0.04, 0.10, 0.12), sand) + light * float3(0.12, 0.34, 0.36);
        return float4(clamp(mix(lightCol, darkCol, u.dark), 0.0, 1.0), 1.0);
    }

    // A cell seed of the Worley grid: its cell plus a slow orbit.
    static float2 cellSeed(float2 id, float t) {
        float2 h = hash22(id);
        return id + 0.5 + 0.38 * float2(sin(t * (0.25 + 0.2 * h.x) + 6.28318 * h.y), cos(t * (0.2 + 0.2 * h.y) + 6.28318 * h.x));
    }

    // Cells: Worley noise (Worley 1996, "A Cellular Texture Basis Function"), a Voronoi diagram of
    // drifting seeds; the seed nearest the pointer is pulled to it and the clicks light the walls.
    fragment float4 wp_cells(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float scale = 5.0;
        float2 p = pixel(in.pos, u) / s * scale, m = u.mouse / s * scale;
        float t = u.time;
        // The seed nearest the pointer, found once per pixel.
        float2 mCell = floor(m), pulledId = mCell;
        float best = 1e9;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 id = mCell + float2(float(i), float(j));
                float dd = length(cellSeed(id, t) - m);
                if (dd < best) { best = dd; pulledId = id; }
            }
        }
        float2 pulled = mix(cellSeed(pulledId, t), m, 0.8 + 0.15 * u.energy);
        float2 dp = pulled - p;
        float f1 = length(dp), f2 = 1e9;
        float2 nearId = pulledId;
        float2 cell = floor(p);
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 id = cell + float2(float(i), float(j));
                if (all(id == pulledId)) continue;
                float dd = length(cellSeed(id, t) - p);
                if (dd < f1) { f2 = f1; f1 = dd; nearId = id; } else if (dd < f2) { f2 = dd; }
            }
        }
        float edge = 1.0 - smoothstep(0.0, 0.06, f2 - f1);
        float glow = rings(p / scale, u, s, 0.45, 0.04);
        float hue = hash21(nearId);
        float3 tint = 0.5 + 0.5 * cos(6.28318 * (hue * 0.35 + 0.55 + float3(0.0, 0.33, 0.67)));
        bool isPulled = all(nearId == pulledId);
        float3 lightCol = mix(float3(0.95, 0.95, 0.94), tint, 0.12) - f1 * 0.05 + (isPulled ? 0.02 : 0.0);
        lightCol = mix(lightCol, float3(0.55, 0.60, 0.66), edge * (0.6 + 0.4 * glow));
        float3 darkCol = mix(float3(0.05, 0.05, 0.07), tint * 0.25, 0.4) + f1 * 0.03 + (isPulled ? 0.03 : 0.0);
        darkCol = mix(darkCol, mix(float3(0.25, 0.55, 0.62), float3(0.6, 0.9, 0.95), clamp(glow, 0.0, 1.0)), edge);
        return float4(clamp(mix(lightCol, darkCol, u.dark), 0.0, 1.0), 1.0);
    }

    // Moire: two ring gratings, one drifting slowly and one centered on the pointer; where they
    // cross, the beat draws the moire fringes (Oster, Wasserman & Zwerling 1964).
    fragment float4 wp_moire(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 p = pixel(in.pos, u) / s, aspect = u.res / s;
        float t = u.time * 0.04;
        float2 c1 = aspect * (0.5 + 0.22 * float2(sin(t * 1.3), cos(t)));
        float freq = 6.28318 * 46.0 * (1.0 + rings(p, u, s, 0.4, 0.05) * 0.02);
        float r1 = length(p - c1), r2 = length(p - u.mouse / s);
        float g1 = 0.5 + 0.5 * cos(r1 * freq);
        float g2 = 0.5 + 0.5 * cos(r2 * freq + u.time * 0.6);
        float ink = g1 * g2;
        float beat = 0.5 + 0.5 * cos((r1 - r2) * freq);
        float3 tint = 0.5 + 0.5 * cos(6.28318 * (beat * 0.2 + t * 0.5 + float3(0.0, 0.33, 0.67)));
        float strength = 0.45 + 0.25 * u.energy;
        float3 lightCol = mix(float3(0.96, 0.95, 0.93), mix(float3(0.35, 0.38, 0.45), tint * 0.6, 0.4), ink * strength);
        float3 darkCol = mix(float3(0.035, 0.04, 0.055), mix(float3(0.55, 0.62, 0.72), tint, 0.4), ink * strength);
        return float4(mix(lightCol, darkCol, u.dark), 1.0);
    }

    // Truchet: quarter-circle arc tiles (Smith 1987, "The Tiling Patterns of Sebastien Truchet and
    // the Topology of Structural Hierarchy"); tiles turn over as the pointer or a click's ring passes.
    fragment float4 wp_truchet(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float gap = max(s / 14.0, 18.0);
        float2 id = floor(px / gap);
        float2 center = (id + 0.5) * gap;
        float dist = length(center - u.mouse) / s;
        float near = smoothstep(0.22 + 0.06 * u.energy, 0.10, dist);
        float swap = clamp(near + rings(center / s, u, s, 0.45, 0.06), 0.0, 1.0);
        float base = step(0.5, hash21(id + floor(u.time * 0.03 + hash21(id * 1.7))));
        float angle = 1.5707963 * (base + swap);
        float c = cos(angle), sn = sin(angle);
        float2 q = float2x2(c, sn, -sn, c) * (px / gap - id - 0.5);
        float d = min(abs(length(q - 0.5) - 0.5), abs(length(q + 0.5) - 0.5)) * gap;
        float w = gap * (0.07 + 0.03 * near);
        float line = smoothstep(w + 1.0, w - 1.0, d);
        float hue = fract(dot(id, float2(0.017, 0.029)) + u.time * 0.008);
        float3 tint = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
        float3 lightCol = mix(float3(0.96, 0.95, 0.93), mix(float3(0.34, 0.37, 0.44), tint * 0.6, 0.35 + 0.3 * near), line);
        float3 darkCol = mix(float3(0.035, 0.04, 0.055), mix(float3(0.50, 0.56, 0.66), tint, 0.4 + 0.3 * near), line);
        return float4(mix(lightCol, darkCol, u.dark), 1.0);
    }

    // Halftone: an amplitude-modulated dot screen at 45 degrees (the printer's halftone, Talbot
    // 1852); each dot's size follows slow fbm, swells near the pointer and pulses with a click.
    fragment float4 wp_halftone(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float gap = max(s / 46.0, 8.0);
        const float2x2 rot = float2x2(0.70710678, 0.70710678, -0.70710678, 0.70710678);
        float2 rp = rot * px;
        float2 cell = floor(rp / gap);
        float2 center = transpose(rot) * ((cell + 0.5) * gap);
        float2 cp = center / s;
        float2 d = cp - u.mouse / s;
        float tone = fbm(cp * 2.2 + float2(u.time * 0.02, u.time * 0.013));
        tone = smoothstep(0.25, 0.75, tone) * 0.55;
        tone += (0.35 + 0.2 * u.energy) * exp(-dot(d, d) * 16.0);
        tone += rings(cp, u, s, 0.4, 0.04) * 0.3;
        float radius = gap * 0.46 * sqrt(clamp(tone, 0.0, 1.0));
        float ink = smoothstep(radius + 0.8, radius - 0.8, length(px - center));
        float hue = fbm(cp * 0.8 - u.time * 0.01);
        float3 tint = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
        float3 lightCol = mix(float3(0.97, 0.96, 0.93), mix(float3(0.20, 0.24, 0.34), tint * 0.5, 0.35), ink);
        float3 darkCol = mix(float3(0.035, 0.04, 0.055), mix(float3(0.70, 0.75, 0.85), tint, 0.35), ink);
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
