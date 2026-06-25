import CmuxSettingsUI
import SwiftUI

/// Cute pixel-art sleeping scene for Sleepy Mode. Renders from the live
/// `SleepyModeSettingsStore` snapshot every frame, so theme / mascot / glow /
/// toggle changes preview instantly. Pixels are drawn on an integer grid so the
/// art stays crisp; all motion is a pure function of the timeline date.
struct SleepyFaceView: View {
    var store = SleepyModeSettingsStore.shared

    var body: some View {
        let config = store.snapshot()
        return ZStack {
            RadialGradient(
                colors: SleepyPalette.glowColors(for: config.glow),
                center: .center,
                startRadius: 0,
                endRadius: 950
            )
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Read the agent census here (main-actor view-builder context),
                // never inside the Canvas renderer (which may run off-main).
                let agents = config.showPets ? SleepyAgentCensus.shared.sample(at: t) : SleepyAgentCounts()
                Canvas { context, size in
                    draw(in: &context, size: size, time: t, config: config, agents: agents)
                }
            }
            hint(config: config)
        }
        .ignoresSafeArea()
    }

    private func hint(config: SleepyModeConfig) -> some View {
        let text = config.requireAuth
            ? String(localized: "sleepyMode.dismissHint", defaultValue: "Touch ID or password to unlock")
            : String(localized: "sleepyMode.dismissHintCasual", defaultValue: "Click or press any key to wake")
        return VStack {
            Spacer()
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(SleepyPalette.colors(for: config.theme)["O"]?.opacity(0.4) ?? .white.opacity(0.4))
                .padding(.bottom, 44)
        }
    }

    // MARK: - Scene

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double, config: SleepyModeConfig, agents: SleepyAgentCounts) {
        let palette = SleepyPalette.colors(for: config.theme)
        let ink = SleepyPalette.ink(for: config.theme)
        let s = min(size.width, size.height)
        let pixel = max(2, (s / 48).rounded())
        let center = CGPoint(x: (size.width / 2).rounded(), y: (size.height * 0.48).rounded())

        if config.showStars { drawStars(in: &ctx, size: size, pixel: pixel, time: t, palette: palette) }
        if config.showMoon { drawMoon(in: &ctx, size: size, pixel: pixel, time: t, palette: palette) }
        if config.showClock { drawClock(in: &ctx, size: size, pixel: pixel, time: t, color: palette["O"] ?? .white) }
        if config.showStatus { drawStatus(in: &ctx, size: size, pixel: pixel, time: t, color: palette["O"] ?? .white) }

        let breath = sin(t * 2 * .pi / 4.6)
        let bob = (breath * 1.4).rounded() * pixel

        if config.mascot == .logoFace {
            drawLogoFace(in: &ctx, center: CGPoint(x: center.x, y: center.y + bob), pixel: pixel, breath: breath, time: t, palette: palette, ink: ink)
        } else {
            let rows = SleepyArt.mascotRows(config.mascot)
            let cols = rows.first?.count ?? 16
            let origin = CGPoint(
                x: (center.x - CGFloat(cols) / 2 * pixel).rounded(),
                y: (center.y - CGFloat(rows.count) / 2 * pixel + bob).rounded()
            )
            drawSprite(in: &ctx, rows: rows, palette: palette, origin: origin, pixel: pixel)
            drawFace(in: &ctx, origin: origin, pixel: pixel, breath: breath, time: t, ink: ink)
            drawCmuxLogo(in: &ctx, center: center, mascotRows: rows.count, pixel: pixel, time: t, palette: palette)
        }

        if config.showZs {
            let zOrigin = config.mascot == .logoFace
                ? CGPoint(x: center.x + 9 * pixel, y: center.y - 7 * pixel + bob)
                : CGPoint(x: center.x + 7 * pixel, y: center.y - 6 * pixel + bob)
            drawSleepZs(in: &ctx, origin: zOrigin, pixel: pixel, time: t, palette: palette)
        }

        if config.showPets {
            drawPets(in: &ctx, size: size, pixel: pixel, time: t, counts: agents)
        }
    }

    // MARK: - Agent pets

    /// One walking pixel pet per open coding agent (Claude/Codex/OpenCode),
    /// to make running lots of agents feel rewarding.
    private func drawPets(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double, counts: SleepyAgentCounts) {
        guard counts.total > 0 else { return }

        let cell = max(2, (pixel * 0.5).rounded())
        let baseline = (size.height * 0.85).rounded()
        let petWidthCells = 8

        var colors: [Color] = []
        let maxPets = 64
        func add(_ count: Int, _ color: Color) {
            for _ in 0..<count where colors.count < maxPets { colors.append(color) }
        }
        add(counts.claude, Color(red: 0.96, green: 0.55, blue: 0.26))
        add(counts.codex, Color(red: 0.62, green: 0.86, blue: 0.97))
        add(counts.opencode, Color(red: 0.45, green: 0.86, blue: 0.55))
        add(counts.other, Color(red: 1.0, green: 0.70, blue: 0.80))

        let span = size.width + CGFloat(petWidthCells * 2) * cell
        for (i, color) in colors.enumerated() {
            let rightward = i % 2 == 0
            let speed = Double(cell) * (5 + Double(i % 4) * 2)
            let offset = Double(i) * 0.137 * Double(span)
            let p = (t * speed + offset).truncatingRemainder(dividingBy: Double(span))
            let travel = CGFloat(p) - CGFloat(petWidthCells) * cell
            let x = (rightward ? travel : size.width - travel).rounded()
            let step = Int(t * 6 + Double(i)) % 2
            let hop = sin(t * 7 + Double(i)) > 0.6 ? -cell : 0
            drawPet(in: &ctx, x: x, y: baseline - 5 * cell + hop, cell: cell, color: color, step: step, facingRight: rightward)
        }
    }

    private func drawPet(in ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, cell: CGFloat, color: Color, step: Int, facingRight: Bool) {
        let ink = Color(red: 0.12, green: 0.13, blue: 0.20)
        func put(_ col: Int, _ row: Int, _ c: Color) {
            ctx.fill(Path(CGRect(x: x + CGFloat(col) * cell, y: y + CGFloat(row) * cell, width: cell, height: cell)), with: .color(c))
        }
        // Body (rows 1-3, cols 0-6) with softened top corners.
        for col in 0...6 {
            for row in 1...3 {
                if row == 1 && (col == 0 || col == 6) { continue }
                put(col, row, color)
            }
        }
        // Ears + tail nub.
        put(1, 0, color)
        put(5, 0, color)
        put(facingRight ? -1 : 7, 1, color)
        // Eye on the leading side.
        put(facingRight ? 5 : 1, 2, ink)
        // Legs alternate as it walks.
        if step == 0 {
            put(1, 4, color); put(5, 4, color)
        } else {
            put(2, 4, color); put(4, 4, color)
        }
    }

    // MARK: - Grid mascot face (eyes/mouth on top of the sprite)

    private func drawFace(in ctx: inout GraphicsContext, origin: CGPoint, pixel: CGFloat, breath: Double, time t: Double, ink: Color) {
        let cells = eyePeek(t) ? SleepyArt.openEyes : SleepyArt.closedEyes
        for cell in cells { fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink) }
        for cell in SleepyArt.mouthTop { fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink) }
        if breath > 0.1 {
            for cell in SleepyArt.mouthOpen { fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink) }
        }
    }

    /// logoFace: cmux chevron `>` as the left eye, a `-` dash as the (winking)
    /// right eye, blush, and a small sleepy mouth.
    private func drawLogoFace(in ctx: inout GraphicsContext, center: CGPoint, pixel: CGFloat, breath: Double, time t: Double, palette: [Character: Color], ink: Color) {
        let eyePixel = max(2, (pixel * 0.7).rounded())
        let chevW = 9, chevH = 13
        let gap = 3 * eyePixel

        // Left eye: cmux chevron.
        let leftOrigin = CGPoint(
            x: (center.x - gap - CGFloat(chevW) * eyePixel).rounded(),
            y: (center.y - CGFloat(chevH) / 2 * eyePixel).rounded()
        )
        drawSprite(in: &ctx, rows: SleepyArt.cmuxLogo, palette: palette, origin: leftOrigin, pixel: eyePixel)

        // Right eye: a sleepy `-` dash, vertically centred to the chevron.
        let dashW = 5, dashY = (center.y - eyePixel).rounded()
        for i in 0..<dashW {
            let rect = CGRect(x: center.x + gap + CGFloat(i) * eyePixel, y: dashY, width: eyePixel, height: eyePixel * 2)
            ctx.fill(Path(rect), with: .color(ink))
        }

        // Blush under each eye.
        if let blush = palette["B"] {
            for cx in [center.x - gap - CGFloat(chevW) / 2 * eyePixel, center.x + gap + CGFloat(dashW) / 2 * eyePixel] {
                let rect = CGRect(x: (cx - 1.5 * eyePixel).rounded(), y: (center.y + 4 * eyePixel).rounded(), width: eyePixel * 3, height: eyePixel * 2)
                ctx.fill(Path(rect), with: .color(blush.opacity(0.85)))
            }
        }

        // Small sleepy mouth: a gentle "‿" that opens a touch on the inhale.
        let mouthY = (center.y + 7 * eyePixel).rounded()
        for cell in [(0, 0), (3, 0), (1, 1), (2, 1)] {
            let rect = CGRect(x: center.x + CGFloat(cell.0 - 2) * eyePixel, y: mouthY + CGFloat(cell.1) * eyePixel, width: eyePixel, height: eyePixel)
            ctx.fill(Path(rect), with: .color(ink))
        }
        if breath > 0.1 {
            let rect = CGRect(x: center.x - eyePixel, y: mouthY + 2 * eyePixel, width: eyePixel * 2, height: eyePixel)
            ctx.fill(Path(rect), with: .color(ink))
        }
    }

    private func eyePeek(_ t: Double) -> Bool {
        let phase = t.truncatingRemainder(dividingBy: 13.0)
        return phase > 0.0 && phase < 0.5
    }

    // MARK: - cmux logo, moon, stars, z's

    private func drawCmuxLogo(in ctx: inout GraphicsContext, center: CGPoint, mascotRows: Int, pixel: CGFloat, time t: Double, palette: [Character: Color]) {
        let cols = SleepyArt.cmuxLogo.first?.count ?? 9
        let logoPixel = max(2, (pixel * 0.8).rounded())
        let origin = CGPoint(
            x: (center.x - CGFloat(cols) / 2 * logoPixel).rounded(),
            y: (center.y + CGFloat(mascotRows) / 2 * pixel + 3 * pixel).rounded()
        )
        let pulse = 0.72 + 0.28 * (0.5 + 0.5 * sin(t * 2 * .pi / 3.2))
        drawSprite(in: &ctx, rows: SleepyArt.cmuxLogo, palette: palette, origin: origin, pixel: logoPixel, alpha: pulse)
    }

    private func drawMoon(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double, palette: [Character: Color]) {
        let moonPixel = max(2, (pixel * 0.9).rounded())
        let origin = CGPoint(x: (size.width * 0.15).rounded(), y: (size.height * 0.18).rounded())
        let glow = 0.85 + 0.15 * sin(t * 2 * .pi / 5.0)
        drawSprite(in: &ctx, rows: SleepyArt.moon, palette: palette, origin: origin, pixel: moonPixel, alpha: glow)
    }

    private func drawStars(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double, palette: [Character: Color]) {
        let starColor = palette["O"] ?? .white
        for star in SleepyArt.stars {
            let twinkle = 0.22 + 0.78 * abs(sin(t * star.speed + star.phase))
            let x = (size.width * star.x).rounded()
            let y = (size.height * star.y).rounded()
            let p = star.big ? max(2, (pixel * 0.55).rounded()) : max(2, (pixel * 0.4).rounded())
            if star.big {
                for cell in [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)] {
                    ctx.fill(Path(CGRect(x: x + CGFloat(cell.0 - 1) * p, y: y + CGFloat(cell.1 - 1) * p, width: p, height: p)), with: .color(starColor.opacity(twinkle)))
                }
            } else {
                ctx.fill(Path(CGRect(x: x, y: y, width: p, height: p)), with: .color(starColor.opacity(twinkle)))
            }
        }
    }

    private func drawSleepZs(in ctx: inout GraphicsContext, origin: CGPoint, pixel: CGFloat, time t: Double, palette: [Character: Color]) {
        let zColor = palette["C"] ?? Color(red: 0.64, green: 0.80, blue: 1.0)
        let period = 3.8
        for i in 0..<3 {
            let progress = ((t / period) + Double(i) / 3.0).truncatingRemainder(dividingBy: 1)
            let opacity = sin(progress * .pi) * 0.9
            let zPixel = max(2, (pixel * (0.32 + 0.34 * progress)).rounded())
            let x = (origin.x + 5 * pixel * progress).rounded()
            let y = (origin.y - 9 * pixel * progress).rounded()
            drawSprite(in: &ctx, rows: SleepyArt.zGlyph, palette: ["Z": zColor], origin: CGPoint(x: x, y: y), pixel: zPixel, alpha: opacity)
        }
    }

    // MARK: - Clock + status

    private func drawClock(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double, color: Color) {
        let comps = Calendar.current.dateComponents([.hour, .minute, .month, .day], from: Date(timeIntervalSinceReferenceDate: t))
        let timeText = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        let dateText = String(format: "%02d/%02d", comps.month ?? 0, comps.day ?? 0)

        let timePixel = max(2, (pixel * 0.9).rounded())
        let datePixel = max(2, (pixel * 0.5).rounded())
        let cx = (size.width / 2).rounded()
        drawText(in: &ctx, text: timeText, centerX: cx, top: (size.height * 0.10).rounded(), pixel: timePixel, color: color)
        drawText(in: &ctx, text: dateText, centerX: cx, top: (size.height * 0.10 + 7 * Double(timePixel) + 4 * Double(datePixel)).rounded(), pixel: datePixel, color: color.opacity(0.7))
    }

    private func drawStatus(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double, color: Color) {
        let status = SleepyStatusProvider.shared.sample(at: t)
        let cell = max(2, (pixel * 0.55).rounded())
        let margin = (size.width * 0.03).rounded()
        let y = (size.height * 0.07).rounded()

        let batCols = 13, batRows = 7
        let baseline = y + CGFloat(batRows) * cell

        var x = (size.width - margin).rounded()
        if let level = status.batteryLevel {
            x -= CGFloat(batCols + 1) * cell  // body + terminal nub
            drawBattery(in: &ctx, x: x, y: y, cell: cell, cols: batCols, rows: batRows, level: level, charging: status.charging, color: color)
            x -= 3 * cell
        }
        x -= CGFloat(4 * 2 + 3) * cell
        drawWifi(in: &ctx, x: x, baseline: baseline, cell: cell, bars: status.wifiBars, color: color)
    }

    /// Clean battery: even 1-cell border, 1-cell inner padding, level fill, nub.
    private func drawBattery(in ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, cell: CGFloat, cols: Int, rows: Int, level: Double, charging: Bool, color: Color) {
        let frame = color.opacity(0.65)
        func put(_ col: Int, _ row: Int, _ c: Color) {
            ctx.fill(Path(CGRect(x: x + CGFloat(col) * cell, y: y + CGFloat(row) * cell, width: cell, height: cell)), with: .color(c))
        }
        // Border.
        for col in 0..<cols { put(col, 0, frame); put(col, rows - 1, frame) }
        for row in 0..<rows { put(0, row, frame); put(cols - 1, row, frame) }
        // Terminal nub.
        put(cols, rows / 2 - 1, frame); put(cols, rows / 2, frame); put(cols, rows / 2 + 1, frame)
        // Level fill (1-cell padding inside the border).
        let region = cols - 4
        let filled = max(0, min(region, Int((Double(region) * level).rounded())))
        let fillColor: Color = charging
            ? Color(red: 0.36, green: 0.88, blue: 0.52)
            : (level <= 0.2 ? Color(red: 1.0, green: 0.45, blue: 0.45) : color.opacity(0.95))
        for col in 0..<filled {
            for row in 2..<(rows - 2) { put(2 + col, row, fillColor) }
        }
    }

    /// Clean Wi-Fi: four 2-wide ascending bars, bottom-aligned.
    private func drawWifi(in ctx: inout GraphicsContext, x: CGFloat, baseline: CGFloat, cell: CGFloat, bars: Int?, color: Color) {
        for i in 0..<4 {
            let active = bars.map { i < $0 } ?? false
            let h = CGFloat(i + 2) * cell
            let bx = x + CGFloat(i) * 3 * cell
            ctx.fill(Path(CGRect(x: bx, y: baseline - h, width: cell * 2, height: h)), with: .color(color.opacity(active ? 0.95 : 0.2)))
        }
    }

    // MARK: - Pixel helpers

    private func drawText(in ctx: inout GraphicsContext, text: String, centerX: CGFloat, top: CGFloat, pixel: CGFloat, color: Color) {
        var widths: [Int] = []
        for ch in text { widths.append(SleepyArt.font[ch]?.first?.count ?? 3) }
        let totalCols = widths.reduce(0, +) + max(0, text.count - 1)
        var x = (centerX - CGFloat(totalCols) / 2 * pixel).rounded()
        for (index, ch) in text.enumerated() {
            if let glyph = SleepyArt.font[ch] {
                drawSprite(in: &ctx, rows: glyph, palette: ["#": color], origin: CGPoint(x: x, y: top), pixel: pixel)
            }
            x += CGFloat(widths[index] + 1) * pixel
        }
    }

    private func drawSprite(in ctx: inout GraphicsContext, rows: [String], palette: [Character: Color], origin: CGPoint, pixel: CGFloat, alpha: Double = 1) {
        for (r, line) in rows.enumerated() {
            for (c, ch) in line.enumerated() where ch != "." {
                guard let color = palette[ch] else { continue }
                let rect = CGRect(x: origin.x + CGFloat(c) * pixel, y: origin.y + CGFloat(r) * pixel, width: pixel, height: pixel)
                ctx.fill(Path(rect), with: .color(alpha >= 1 ? color : color.opacity(alpha)))
            }
        }
    }

    private func fillCell(in ctx: inout GraphicsContext, origin: CGPoint, pixel: CGFloat, col: Int, row: Int, color: Color) {
        ctx.fill(Path(CGRect(x: origin.x + CGFloat(col) * pixel, y: origin.y + CGFloat(row) * pixel, width: pixel, height: pixel)), with: .color(color))
    }
}
