/// The calm living wallpapers' Metal source, appended to ``BackdropShaderSource/source``: slow,
/// low-contrast motion that sits behind text (ask-customization-packs, Leo: "we can try out a lot
/// more stuff there ... what would actually look good and not eyesore-ish"). Every one keeps its
/// brightest pixel close to its darkest, moves at a drift, and answers the pointer softly.
nonisolated extension BackdropShaderSource {
    static let calmSource = #"""

    static float2x2 rot2(float a) { float c = cos(a), s = sin(a); return float2x2(c, s, -s, c); }

    // Content near the pointer is pushed away from it: the offset to sample from at p.
    static float2 pushOff(float2 p, float2 m, float energy, float k) {
        float2 d = p - m;
        return -d * k * (0.4 + energy) * exp(-dot(d, d) * 20.0);
    }

    // One layer of petals: a grid of cells, each holding one petal that sways down and tumbles.
    // Returns its coverage; `tone` is that petal's own 0...1 shade.
    static float petals(float2 p, float scale, float seed, float fall, float soft, float t, thread float& tone) {
        float2 q = p * scale + float2(-t * 0.03 * scale, t * fall * scale);
        float2 cell = floor(q), f = fract(q);
        float h1 = hash21(cell + seed), h2 = hash21(cell + seed + 17.0), h3 = hash21(cell + seed + 41.0);
        float r = 0.10 + 0.07 * h2;
        float2 c = float2(0.5 + 0.22 * sin(t * (0.25 + 0.25 * h1) + h1 * 6.28),
                          0.5 + 0.12 * sin(t * (0.30 + 0.20 * h2) + h2 * 6.28));
        float ang = h2 * 6.28 + t * (0.25 + 0.35 * h1) * (h3 < 0.5 ? -1.0 : 1.0);
        float2 l = rot2(-ang) * (f - c);
        float flip = 0.35 + 0.65 * abs(cos(t * 0.5 * (0.5 + h2) + h1 * 6.28));
        float w = max(0.55 * flip * (1.0 - 0.35 * l.x / r), 0.05);
        float e = length(float2(l.x / r, l.y / (r * w)));
        tone = h1;
        return (1.0 - smoothstep(1.0 - soft, 1.0 + soft, e)) * step(0.35, h3) * (0.6 + 0.4 * h2);
    }

    // Sakura: petals drifting down through a dusk sky; the pointer parts them like a breath of wind.
    fragment float4 wp_sakura(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float aspect = u.res.x / s, height = u.res.y / s;
        float vy = px.y / u.res.y;
        float t = u.time;
        float3 darkSky = mix(mix(float3(0.29, 0.16, 0.24), float3(0.15, 0.10, 0.21), smoothstep(0.0, 0.5, vy)),
                             float3(0.05, 0.05, 0.13), smoothstep(0.45, 1.0, vy));
        float3 lightSky = mix(mix(float3(1.0, 0.90, 0.80), float3(0.93, 0.80, 0.84), smoothstep(0.0, 0.5, vy)),
                              float3(0.72, 0.74, 0.89), smoothstep(0.45, 1.0, vy));
        float3 col = mix(lightSky, darkSky, u.dark);
        float band = smoothstep(0.55, 0.85, fbm(float2(p.x * 1.1 + t * 0.004, p.y * 4.0))) * smoothstep(0.1, 0.4, vy) * (1.0 - smoothstep(0.5, 0.8, vy));
        col = mix(col, mix(float3(1.0, 0.93, 0.90), float3(0.55, 0.32, 0.42), u.dark), band * 0.20);
        float2 moon = float2(0.76 * aspect, 0.78 * height);
        float md = length(p - moon);
        col = mix(col, mix(float3(1.0, 0.98, 0.94), float3(0.88, 0.80, 0.78), u.dark),
                  (1.0 - smoothstep(0.050, 0.058, md)) * mix(0.55, 0.30, u.dark) + exp(-md * md * 40.0) * 0.08);
        float2 off = pushOff(p, m, u.energy, 0.5);
        float3 pink = mix(float3(0.93, 0.55, 0.66), float3(0.85, 0.58, 0.70), u.dark);
        float3 pale = mix(float3(0.98, 0.72, 0.78), float3(0.97, 0.76, 0.82), u.dark);
        float tone;
        float a = petals(p + off, 3.4, 1.0, 0.035, 0.40, t, tone);
        col = mix(col, mix(pink, pale, tone), a * 0.30);
        a = petals(p + off, 2.0, 7.0, 0.055, 0.25, t, tone);
        col = mix(col, mix(pink, pale, tone), a * 0.50);
        a = petals(p + off, 1.2, 13.0, 0.085, 0.38, t, tone);
        col = mix(col, mix(pink, pale, tone), a * 0.42);
        col += rings(p, u, s, 0.4, 0.03) * mix(float3(-0.05, -0.03, -0.02), float3(0.10, 0.05, 0.08), u.dark);
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // Sumi: ink in water. Two slow warps of noise make washes that bloom and thin; where the ink
    // thins its edge pools a little darker, as it does on paper. A click drops ink that spreads.
    fragment float4 wp_sumi(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float t = u.time * 0.02;
        float2 q = (p + pushOff(p, m, u.energy, 0.25)) * 1.3;
        float2 w = float2(fbm(q * 1.2 + float2(t, -t * 0.7)), fbm(q * 1.2 + float2(5.2, 1.3) + float2(-t * 0.6, t)));
        float f = fbm(q * 0.9 + 2.0 * w);
        float th = 0.54 + 0.05 * sin(u.time * 0.04);
        float ink = smoothstep(th, th + 0.26, f) * 0.50 + smoothstep(0.35, 0.60, w.x) * 0.14;
        ink += exp(-sq((f - th) / 0.03)) * 0.10;
        for (int i = 0; i < 4; i++) {
            float4 r = u.rings[i];
            float age = u.time - r.z;
            if (r.w < 0.5 || age < 0.0 || age > 12.0) continue;
            float2 d = p - r.xy / s;
            float radius = 0.04 + 0.11 * sqrt(age);
            float edge = radius * (0.9 + 0.35 * fbm(p * 7.0));
            ink += (1.0 - smoothstep(edge * 0.6, edge, length(d))) * 0.35 * exp(-age * 0.25);
        }
        float2 dm = p - m;
        ink += exp(-dot(dm, dm) * 40.0) * 0.05 * (0.5 + u.energy);
        float grain = (hash21(floor(px)) - 0.5) * 0.012;
        ink = clamp(ink, 0.0, 0.75);
        float3 lightCol = mix(float3(0.95, 0.93, 0.88), float3(0.20, 0.22, 0.25), ink);
        float3 darkCol = mix(float3(0.045, 0.050, 0.055), float3(0.52, 0.57, 0.59), ink * 0.5);
        return float4(clamp(mix(lightCol, darkCol, u.dark) + grain, 0.0, 1.0), 1.0);
    }

    // Light on the floor of a pond: the folding network of caustics a ripple throws.
    static float causticNet(float2 uv, float time) {
        const float tau = 6.28318530718;
        float2 p = fmod(uv * tau, tau) - 250.0;
        float2 i = p;
        float c = 1.0;
        const float inten = 0.005;
        for (int n = 0; n < 4; n++) {
            float t = time * (1.0 - 3.5 / float(n + 1));
            i = p + float2(cos(t - i.x) + sin(t + i.y), sin(t - i.y) + cos(t + i.x));
            c += 1.0 / length(float2(p.x / (sin(i.x + t) / inten), p.y / (cos(i.y + t) / inten)));
        }
        c /= 4.0;
        c = 1.17 - pow(c, 1.4);
        return pow(abs(c), 8.0);
    }

    // One koi, seen from above through the water: a blurred body of circles trailing its head
    // along a slow loop. Returns its coverage and writes its color.
    static float koiBody(float2 p, float2 m, float energy, float t, float seed, float aspect, float height, thread float3& color) {
        float h1 = hash21(float2(seed, 3.1)), h2 = hash21(float2(seed, 8.7));
        float cover = 0.0;
        for (int k = 0; k < 7; k++) {
            float fk = float(k);
            float tau = t - 0.5 * fk;
            float2 c = float2(aspect * (0.5 + 0.38 * sin(0.14 * tau * (0.8 + 0.4 * h1) + h1 * 6.28)),
                              height * (0.5 + 0.34 * sin(0.19 * tau * (0.8 + 0.4 * h2) + h2 * 6.28)));
            c.y += 0.006 * fk * sin(t * 2.0 - fk);
            float2 away = c - m;
            c += away * 0.35 * (0.4 + energy) * exp(-dot(away, away) * 12.0);
            float r = 0.034 * (1.0 - 0.11 * fk);
            float a = 1.0 - smoothstep(r - 0.014, r + 0.014, length(p - c));
            float3 segColor = hash21(float2(seed, fk)) < 0.5 ? float3(0.95, 0.50, 0.22) : float3(0.95, 0.92, 0.85);
            color = k == 0 ? segColor : mix(color, segColor, a);
            cover = max(cover, a);
        }
        return cover;
    }

    // Koi: the light a pond throws on its floor, and three koi slow beneath it. The koi swim
    // clear of the pointer and a click sends a ring of light across the water.
    fragment float4 wp_koi(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float aspect = u.res.x / s, height = u.res.y / s;
        float vy = px.y / u.res.y;
        float t = u.time;
        float3 lightWater = mix(float3(0.66, 0.82, 0.82), float3(0.78, 0.91, 0.89), vy);
        float3 darkWater = mix(float3(0.010, 0.060, 0.075), float3(0.020, 0.110, 0.130), vy);
        float3 col = mix(lightWater, darkWater, u.dark);
        float2 sway = float2(vnoise(p * 2.0 + t * 0.03), vnoise(p * 2.0 + 9.0 - t * 0.03)) * 0.06;
        float c = causticNet(p * 0.8 + sway, t * 0.35);
        col += c * mix(float3(0.16, 0.16, 0.12), float3(0.07, 0.24, 0.24), u.dark);
        for (int i = 0; i < 3; i++) {
            float3 kc = float3(0.0);
            float a = koiBody(p, m, u.energy, t, float(i) * 3.7 + 1.0, aspect, height, kc);
            col = mix(col, kc * mix(1.0, 0.8, u.dark), a * mix(0.30, 0.34, u.dark));
        }
        col += rings(p, u, s, 0.35, 0.03) * mix(float3(0.06, 0.06, 0.05), float3(0.05, 0.17, 0.17), u.dark);
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // One layer of snowflakes: soft discs swaying down; coverage in 0...1.
    static float flakes(float2 p, float scale, float seed, float fall, float soft, float t) {
        float2 q = p * scale + float2(-t * 0.012 * scale, t * fall * scale);
        float2 cell = floor(q), f = fract(q);
        float h1 = hash21(cell + seed), h2 = hash21(cell + seed + 23.0), h3 = hash21(cell + seed + 59.0);
        float r = 0.10 + 0.08 * h2;
        float2 c = float2(0.5 + 0.25 * sin(t * (0.3 + 0.4 * h1) + h2 * 6.28), 0.5 + 0.2 * sin(t * 0.2 + h1 * 6.28));
        float d = length(f - c);
        return (1.0 - smoothstep(r * (1.0 - soft), r * (1.0 + soft), d)) * step(0.3, h3);
    }

    // The height of a ridge line at x as a 0...1 fraction of the window, from three octaves.
    static float ridgeLine(float x, float seed, float base, float amp) {
        float n = 0.5 * vnoise(float2(x * 1.5 + seed, seed)) + 0.25 * vnoise(float2(x * 3.1 + seed, seed + 3.0))
            + 0.125 * vnoise(float2(x * 6.7 + seed, seed + 7.0));
        return base + amp * n;
    }

    // Snowfall: flakes in three depths drifting down over two ridges in the haze; the pointer
    // sends a gust through them.
    fragment float4 wp_snowfall(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float vy = px.y / u.res.y;
        float t = u.time;
        float3 darkSky = mix(float3(0.11, 0.15, 0.23), float3(0.03, 0.05, 0.10), smoothstep(0.2, 1.0, vy));
        float3 lightSky = mix(float3(0.95, 0.96, 0.98), float3(0.74, 0.79, 0.88), smoothstep(0.2, 1.0, vy));
        float3 col = mix(lightSky, darkSky, u.dark);
        float star = step(0.997, hash21(floor(px / 2.0))) * (0.6 + 0.4 * sin(t * 0.8 + hash21(floor(px / 2.0) + 5.0) * 40.0));
        col += star * smoothstep(0.55, 0.9, vy) * 0.30 * u.dark;
        float ridgeFar = ridgeLine(p.x, 2.0, 0.22, 0.20);
        float ridgeNear = ridgeLine(p.x, 11.0, 0.08, 0.16);
        float3 farCol = mix(float3(0.74, 0.79, 0.86), float3(0.075, 0.105, 0.165), u.dark);
        float3 nearCol = mix(float3(0.60, 0.66, 0.76), float3(0.030, 0.045, 0.080), u.dark);
        float e = 1.5 / u.res.y;
        col = mix(col, farCol, 1.0 - smoothstep(ridgeFar - e, ridgeFar + e, vy));
        col += exp(-sq((vy - ridgeFar) / 0.02)) * (vy > ridgeFar ? 0.03 : 0.0) * mix(float3(0.0), float3(0.6, 0.7, 0.9), u.dark);
        col = mix(col, nearCol, 1.0 - smoothstep(ridgeNear - e, ridgeNear + e, vy));
        float2 q = p + pushOff(p, m, u.energy, 1.0) * 0.8 + float2(-0.05 * u.energy, 0.0);
        float3 snow = mix(float3(1.0), float3(0.86, 0.91, 0.98), u.dark);
        col = mix(col, snow, flakes(q, 14.0, 1.0, 0.020, 0.6, t) * 0.40);
        col = mix(col, snow, flakes(q, 8.0, 5.0, 0.035, 0.4, t) * 0.55);
        col = mix(col, snow, flakes(q, 4.5, 9.0, 0.055, 0.5, t) * 0.65);
        col += rings(p, u, s, 0.4, 0.03) * mix(float3(-0.04), float3(0.06, 0.08, 0.12), u.dark);
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // One layer of paper-lantern bokeh: a grid of cells, each holding one soft disc with a faint
    // brighter rim, rising and flickering slowly. Returns its coverage; `tone` picks its color.
    static float bokeh(float2 p, float2 m, float energy, float scale, float seed, float rise, float t, thread float& tone) {
        float2 q = p * scale + float2(0.0, -t * rise * scale);
        float2 cell = floor(q), f = fract(q);
        float h1 = hash21(cell + seed), h2 = hash21(cell + seed + 13.0), h3 = hash21(cell + seed + 37.0);
        float r = 0.14 + 0.16 * h2;
        float2 c = float2(r + (1.0 - 2.0 * r) * (0.5 + 0.5 * sin(t * 0.08 + h1 * 6.28)),
                          r + (1.0 - 2.0 * r) * h1);
        float d = length(f - c) / r;
        float glow = exp(-dot(p - m, p - m) * 14.0) * (0.4 + energy);
        float flicker = 0.75 + 0.25 * sin(t * 0.35 * (0.6 + h2) + h3 * 20.0);
        float disc = (1.0 - smoothstep(0.88, 1.0, d)) * 0.6 + exp(-sq((d - 0.95) / 0.07)) * 0.4;
        tone = h3;
        return disc * flicker * step(0.3, h1 + 0.2 * h3) * (1.0 + glow * 1.2);
    }

    // Lanterns: the warm bokeh of paper lanterns, a few soft discs of light rising slowly through
    // the dark; those near the pointer glow a little brighter.
    fragment float4 wp_lanterns(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float vy = px.y / u.res.y;
        float t = u.time;
        float3 col = mix(mix(float3(0.96, 0.87, 0.78), float3(0.99, 0.95, 0.89), smoothstep(0.0, 0.8, vy)),
                         mix(float3(0.115, 0.055, 0.045), float3(0.035, 0.025, 0.040), smoothstep(0.0, 0.9, vy)), u.dark);
        float2 off = pushOff(p, m, u.energy, 0.3);
        float tone;
        float a;
        float3 amber = float3(1.0, 0.62, 0.22), rose = float3(0.95, 0.42, 0.40), gold = float3(1.0, 0.82, 0.42);
        for (int i = 0; i < 3; i++) {
            float sc = i == 0 ? 4.2 : (i == 1 ? 2.6 : 1.6);
            float rise = i == 0 ? 0.014 : (i == 1 ? 0.022 : 0.030);
            a = bokeh(p + off, m, u.energy, sc, 3.0 + 10.0 * float(i), rise, t, tone);
            float3 tint = tone < 0.4 ? mix(gold, amber, tone / 0.4) : mix(amber, rose, (tone - 0.4) / 0.6);
            float k = i == 0 ? 0.12 : (i == 1 ? 0.16 : 0.20);
            float3 lit = 1.0 - (1.0 - col) * (1.0 - tint * a * k * 1.6);
            float3 tinted = mix(col, tint * 0.97, a * k * 1.3);
            col = mix(tinted, lit, u.dark);
        }
        col += rings(p, u, s, 0.4, 0.03) * mix(float3(0.0, -0.02, -0.04), float3(0.12, 0.07, 0.03), u.dark);
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // The blurred scene behind the glass: out-of-focus lights drifting in the dark (a gray day
    // in the light appearance), as two layers of soft discs.
    static float3 rainScene(float2 p, constant Uniforms& u, float2 m) {
        float t = u.time;
        float3 col = mix(float3(0.80, 0.84, 0.88), float3(0.020, 0.028, 0.050), u.dark);
        float2 dm = p - m;
        col += exp(-dot(dm, dm) * 16.0) * mix(float3(0.05, 0.04, 0.01), float3(0.05, 0.035, 0.015), u.dark);
        for (int i = 0; i < 2; i++) {
            float sc = i == 0 ? 3.0 : 1.7;
            float2 q = p * sc + float2(t * 0.004 * sc, 0.0) + float(i) * 7.0;
            float2 cell = floor(q), f = fract(q);
            float h1 = hash21(cell), h2 = hash21(cell + 11.0), h3 = hash21(cell + 29.0);
            float r = 0.18 + 0.16 * h2;
            float2 c = float2(r + (1.0 - 2.0 * r) * h1, r + (1.0 - 2.0 * r) * h3);
            float d = length(f - c) / r;
            float a = (1.0 - smoothstep(0.55, 1.0, d)) * step(0.35, h2 + 0.3 * h1);
            float3 tint = h3 < 0.33 ? float3(1.0, 0.75, 0.45) : (h3 < 0.66 ? float3(0.45, 0.70, 1.0) : float3(0.95, 0.48, 0.62));
            col = mix(col, tint * 0.95, a * mix(0.10, 0.32, u.dark));
        }
        return col;
    }

    // One drop on the glass at c: it shows the scene upside down through itself, darker at its
    // rim and heavier toward the bottom, with a small highlight up and left.
    static float3 glassDrop(float3 col, float2 p, float2 c, float r, constant Uniforms& u, float2 m, float e) {
        float2 l = (p - c) / r;
        l.y = l.y > 0.0 ? l.y / 1.15 : l.y / 1.0;
        float d = length(l);
        float cover = 1.0 - smoothstep(1.0 - e / r, 1.0 + e / r, d);
        if (cover <= 0.0) return col;
        float3 seen = rainScene(c - (p - c) * 2.2, u, m);
        float3 body = mix(seen, col, 0.15) * mix(1.04, 1.25, u.dark);
        float rim = smoothstep(0.55, 1.0, d);
        body *= 1.0 - 0.22 * rim * mix(1.0, 0.5, u.dark);
        float hot = exp(-(sq(l.x + 0.35) + sq(l.y - 0.4)) / 0.03) * mix(0.55, 0.30, u.dark);
        float crescent = exp(-sq((d - 0.85) / 0.12)) * smoothstep(0.1, -0.7, l.y) * 0.12;
        body += hot + crescent;
        return mix(col, body, cover);
    }

    // Rain: a window in the rain at night: city lights out of focus behind the glass, small drops
    // standing on it and a few large ones sliding down in fits, each leaving a faint trail.
    fragment float4 wp_rain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float s = min(u.res.x, u.res.y);
        float2 px = pixel(in.pos, u);
        float2 p = px / s, m = u.mouse / s;
        float height = u.res.y / s;
        float t = u.time;
        float e = 1.0 / s;
        float3 col = rainScene(p, u, m);
        // Drops standing on the glass, two sizes, each breathing in and out of view.
        for (int i = 0; i < 2; i++) {
            float sc = i == 0 ? 11.0 : 6.5;
            float2 q = p * sc + float(i) * 5.0;
            float2 cell = floor(q), f = fract(q);
            float h1 = hash21(cell + 3.0), h2 = hash21(cell + 19.0), h3 = hash21(cell + 43.0);
            float r = (i == 0 ? 0.14 : 0.16) + 0.12 * h2;
            float breathe = 0.85 + 0.15 * sin(t * 0.15 + h3 * 20.0);
            float2 c = float2(r + (1.0 - 2.0 * r) * h1, r + (1.0 - 2.0 * r) * h3);
            if (h2 + 0.3 * h1 > 0.95) {
                col = glassDrop(col, f / sc, c / sc, r * breathe / sc, u, m, e);
            }
        }
        // Big drops sliding down their own columns, stopping and starting, with a trail above.
        float width = 0.19;
        float colId = floor(p.x / width);
        float g1 = hash21(float2(colId, 2.0)), g2 = hash21(float2(colId, 6.0)), g3 = hash21(float2(colId, 9.0));
        float span = height + 0.3;
        float travel = t * (0.012 + 0.018 * g2) + 0.020 * sin(t * 0.35 + g3 * 30.0) + g3 * span;
        float yd = height + 0.1 - fmod(travel, span);
        float xd = (colId + 0.2 + 0.6 * g1) * width + 0.003 * sin(yd * 9.0);
        float above = p.y - yd;
        if (above > 0.0 && above < 0.4) {
            float trail = exp(-sq((p.x - xd) / 0.0022)) * sq(1.0 - above / 0.4);
            col += trail * mix(float3(0.04), float3(0.035), u.dark) * (g1 > 0.3 ? 1.0 : 0.0);
        }
        if (g1 > 0.3) {
            col = glassDrop(col, p, float2(xd, yd), 0.016 + 0.008 * g2, u, m, e);
        }
        col += rings(p, u, s, 0.4, 0.025) * mix(float3(0.03), float3(0.06, 0.07, 0.09), u.dark);
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    """#
}
