import SwiftUI

/// Cute pixel-art sleeping scene for Sleepy Mode: a little cmux mascot dozing
/// in a cmux-cyan nightcap under a pixel moon and twinkling stars, with a bold
/// pixel cmux logo as the brand mark. Everything is a pure function of the
/// timeline date (no mutable animation state), and pixels are drawn on an
/// integer grid so the art stays crisp.
struct SleepyFaceView: View {
    var body: some View {
        ZStack {
            backgroundGradient
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            hint
        }
        .ignoresSafeArea()
    }

    private var backgroundGradient: some View {
        RadialGradient(
            colors: [
                Color(red: 0.08, green: 0.10, blue: 0.20),
                Color(red: 0.02, green: 0.02, blue: 0.06),
            ],
            center: .center,
            startRadius: 0,
            endRadius: 950
        )
    }

    private var hint: some View {
        VStack {
            Spacer()
            Text(String(localized: "sleepyMode.dismissHint", defaultValue: "Touch ID or password to unlock"))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(SleepyPixelArt.face.opacity(0.4))
                .padding(.bottom, 44)
        }
    }

    // MARK: - Scene

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let s = min(size.width, size.height)
        let pixel = max(2, (s / 48).rounded())
        let center = CGPoint(x: (size.width / 2).rounded(), y: (size.height * 0.44).rounded())

        drawStars(in: &ctx, size: size, pixel: pixel, time: t)
        drawMoon(in: &ctx, size: size, pixel: pixel, time: t)

        // Breathing: a gentle, pixel-quantized vertical bob so the sprite never
        // blurs between frames.
        let breath = sin(t * 2 * .pi / 4.6)
        let bob = (sin(t * 2 * .pi / 4.6) * 1.4).rounded() * pixel

        // Mascot, centered on the breathing offset.
        let mascotCols = SleepyPixelArt.mascot.first?.count ?? 16
        let mascotRows = SleepyPixelArt.mascot.count
        let mascotOrigin = CGPoint(
            x: (center.x - CGFloat(mascotCols) / 2 * pixel).rounded(),
            y: (center.y - CGFloat(mascotRows) / 2 * pixel + bob).rounded()
        )
        drawSprite(in: &ctx, rows: SleepyPixelArt.mascot, palette: SleepyPixelArt.palette, origin: mascotOrigin, pixel: pixel)
        drawFace(in: &ctx, origin: mascotOrigin, pixel: pixel, breath: breath, time: t)

        drawSleepZs(in: &ctx, origin: CGPoint(x: mascotOrigin.x + 14 * pixel, y: mascotOrigin.y + 2 * pixel), pixel: pixel, time: t)

        // cmux logo: a bold pixel chevron under the mascot, softly pulsing.
        let logoCols = SleepyPixelArt.cmuxLogo.first?.count ?? 9
        let logoPixel = max(2, (pixel * 0.8).rounded())
        let logoOrigin = CGPoint(
            x: (center.x - CGFloat(logoCols) / 2 * logoPixel).rounded(),
            y: (center.y + CGFloat(mascotRows) / 2 * pixel + 3 * pixel).rounded()
        )
        let pulse = 0.72 + 0.28 * (0.5 + 0.5 * sin(t * 2 * .pi / 3.2))
        drawSprite(in: &ctx, rows: SleepyPixelArt.cmuxLogo, palette: SleepyPixelArt.palette, origin: logoOrigin, pixel: logoPixel, alpha: pulse)
    }

    // MARK: - Face (drawn on top of the mascot sprite so eyes/mouth can animate)

    private func drawFace(in ctx: inout GraphicsContext, origin: CGPoint, pixel: CGFloat, breath: Double, time t: Double) {
        let ink = SleepyPixelArt.ink
        let open = eyePeek(t)

        if open {
            // Peeking: small round open eyes.
            for cell in [(5, 7), (6, 7), (5, 8), (6, 8), (9, 7), (10, 7), (9, 8), (10, 8)] {
                fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink)
            }
        } else {
            // Asleep: gentle closed "‿" arcs.
            for cell in [(4, 7), (7, 7), (5, 8), (6, 8), (8, 7), (11, 7), (9, 8), (10, 8)] {
                fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink)
            }
        }

        // Breathing mouth: a tiny opening that grows on the inhale.
        fillCell(in: &ctx, origin: origin, pixel: pixel, col: 7, row: 10, color: ink)
        fillCell(in: &ctx, origin: origin, pixel: pixel, col: 8, row: 10, color: ink)
        if breath > 0.1 {
            fillCell(in: &ctx, origin: origin, pixel: pixel, col: 7, row: 11, color: ink)
            fillCell(in: &ctx, origin: origin, pixel: pixel, col: 8, row: 11, color: ink)
        }
    }

    /// Mostly asleep; briefly peeks every ~13s.
    private func eyePeek(_ t: Double) -> Bool {
        let phase = t.truncatingRemainder(dividingBy: 13.0)
        return phase > 0.0 && phase < 0.5
    }

    // MARK: - Moon, stars, z's

    private func drawMoon(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double) {
        let moonPixel = max(2, (pixel * 0.9).rounded())
        let origin = CGPoint(
            x: (size.width * 0.16).rounded(),
            y: (size.height * 0.17).rounded()
        )
        let glow = 0.85 + 0.15 * sin(t * 2 * .pi / 5.0)
        drawSprite(in: &ctx, rows: SleepyPixelArt.moon, palette: SleepyPixelArt.palette, origin: origin, pixel: moonPixel, alpha: glow)
    }

    private func drawStars(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double) {
        let starColor = Color(red: 0.85, green: 0.90, blue: 1.0)
        for star in SleepyPixelArt.stars {
            let twinkle = 0.25 + 0.75 * abs(sin(t * star.speed + star.phase))
            let x = (size.width * star.x).rounded()
            let y = (size.height * star.y).rounded()
            let p = star.big ? max(2, (pixel * 0.6).rounded()) : max(2, (pixel * 0.4).rounded())
            if star.big {
                // Plus-shaped twinkle.
                for cell in [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)] {
                    let rect = CGRect(x: x + CGFloat(cell.0 - 1) * p, y: y + CGFloat(cell.1 - 1) * p, width: p, height: p)
                    ctx.fill(Path(rect), with: .color(starColor.opacity(twinkle)))
                }
            } else {
                ctx.fill(Path(CGRect(x: x, y: y, width: p, height: p)), with: .color(starColor.opacity(twinkle)))
            }
        }
    }

    private func drawSleepZs(in ctx: inout GraphicsContext, origin: CGPoint, pixel: CGFloat, time t: Double) {
        let zColor = Color(red: 0.64, green: 0.80, blue: 1.0)
        let period = 3.8
        for i in 0..<3 {
            let progress = ((t / period) + Double(i) / 3.0).truncatingRemainder(dividingBy: 1)
            let opacity = sin(progress * .pi) * 0.9
            let zPixel = max(2, (pixel * (0.32 + 0.34 * progress)).rounded())
            let x = (origin.x + 5 * pixel * progress).rounded()
            let y = (origin.y - 9 * pixel * progress).rounded()
            drawSprite(
                in: &ctx,
                rows: SleepyPixelArt.zGlyph,
                palette: ["Z": zColor],
                origin: CGPoint(x: x, y: y),
                pixel: zPixel,
                alpha: opacity
            )
        }
    }

    // MARK: - Pixel helpers

    private func drawSprite(
        in ctx: inout GraphicsContext,
        rows: [String],
        palette: [Character: Color],
        origin: CGPoint,
        pixel: CGFloat,
        alpha: Double = 1
    ) {
        for (r, line) in rows.enumerated() {
            for (c, ch) in line.enumerated() where ch != "." {
                guard let color = palette[ch] else { continue }
                let rect = CGRect(x: origin.x + CGFloat(c) * pixel, y: origin.y + CGFloat(r) * pixel, width: pixel, height: pixel)
                ctx.fill(Path(rect), with: .color(alpha >= 1 ? color : color.opacity(alpha)))
            }
        }
    }

    private func fillCell(
        in ctx: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat,
        col: Int,
        row: Int,
        color: Color
    ) {
        let rect = CGRect(x: origin.x + CGFloat(col) * pixel, y: origin.y + CGFloat(row) * pixel, width: pixel, height: pixel)
        ctx.fill(Path(rect), with: .color(color))
    }
}

/// Pixel-art assets for Sleepy Mode. Sprites are arrays of equal-length rows;
/// each non-"." character maps to a palette color.
private enum SleepyPixelArt {
    static let face = Color(red: 0.88, green: 0.93, blue: 1.0)
    static let ink = Color(red: 0.20, green: 0.24, blue: 0.42)

    static let palette: [Character: Color] = [
        "O": Color(red: 0.88, green: 0.93, blue: 1.0),   // face
        "o": Color(red: 0.69, green: 0.77, blue: 0.93),  // face shade
        "P": Color(red: 0.36, green: 0.84, blue: 1.0),   // nightcap (cmux cyan)
        "p": Color(red: 0.18, green: 0.55, blue: 0.86),  // nightcap shade
        "W": Color(red: 1.0, green: 1.0, blue: 1.0),     // pom-pom
        "B": Color(red: 1.0, green: 0.60, blue: 0.71),   // blush
        "C": Color(red: 0.42, green: 0.87, blue: 1.0),   // cmux logo
        "c": Color(red: 0.16, green: 0.52, blue: 0.93),  // cmux logo shade
        "Y": Color(red: 1.0, green: 0.93, blue: 0.70),   // moon
    ]

    /// Head + droopy nightcap (16x16). Eyes/mouth are drawn procedurally on top.
    static let mascot: [String] = [
        "............WW..",
        "..........PPWW..",
        "........PPPPP...",
        "......PPPPPPP...",
        "....PPPPPPPPP...",
        "...PPPPPPPPPP...",
        "...pOOOOOOOOp...",
        "..OOOOOOOOOOOO..",
        "..OBBOOOOOOBBO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "...OOOOOOOOOo...",
        "...OOOOOOOOoo...",
        "....OOOOOOoo....",
        ".....OOOOoo.....",
        "................",
    ]

    /// Bold right-pointing cmux chevron (9x13).
    static let cmuxLogo: [String] = [
        "CCC......",
        "CCCC.....",
        ".CCCC....",
        "..CCCC...",
        "...CCCC..",
        "....CCCC.",
        ".....CCCC",
        "....cCCC.",
        "...cCCC..",
        "..cCCC...",
        ".cCCC....",
        "cCCC.....",
        "cCC......",
    ]

    /// Small left-facing crescent moon (5x5).
    static let moon: [String] = [
        ".YY..",
        "YYY..",
        "YY...",
        "YYY..",
        ".YY..",
    ]

    /// Pixel "Z" (5x5).
    static let zGlyph: [String] = [
        "ZZZZZ",
        "...Z.",
        "..Z..",
        ".Z...",
        "ZZZZZ",
    ]

    struct Star {
        let x: Double
        let y: Double
        let big: Bool
        let speed: Double
        let phase: Double
    }

    static let stars: [Star] = [
        Star(x: 0.24, y: 0.30, big: true, speed: 1.7, phase: 0.0),
        Star(x: 0.78, y: 0.20, big: true, speed: 2.1, phase: 1.2),
        Star(x: 0.68, y: 0.36, big: false, speed: 2.6, phase: 0.5),
        Star(x: 0.86, y: 0.46, big: false, speed: 1.9, phase: 2.0),
        Star(x: 0.14, y: 0.52, big: false, speed: 2.3, phase: 3.1),
        Star(x: 0.30, y: 0.66, big: true, speed: 1.5, phase: 0.8),
        Star(x: 0.82, y: 0.68, big: false, speed: 2.8, phase: 1.7),
        Star(x: 0.50, y: 0.16, big: false, speed: 2.2, phase: 2.6),
    ]
}
