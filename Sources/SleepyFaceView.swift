import CmuxSettingsUI
import SwiftUI

/// Cute pixel-art sleeping scene for Sleepy Mode. Renders from the live
/// `SleepyModeSettingsStore` snapshot every frame, so theme / mascot / glow /
/// toggle changes preview instantly. Pixels are drawn on an integer grid so the
/// art stays crisp; all motion is a pure function of the timeline date.
struct SleepyFaceView: View {
    var store: SleepyModeSettingsStore
    var power: any SleepyPowerControlling
    /// Whether the controller actually acquired the keep-awake power assertions.
    /// When false, the badge says so instead of falsely claiming the Mac is safe.
    var keepingAwake: Bool
    /// Frame-sampled data providers, injected by the controller.
    var agentCensus: any SleepyAgentCensusing
    var statusProvider: any SleepyStatusProviding
    /// Shared Low Power UI state (one instance across all per-display overlays).
    var powerUIState: SleepyPowerUIState

    // Easter-egg reactions: timeIntervalSinceReferenceDate when poked.
    @State private var mascotReactAt: Double?
    @State private var mascotPokes = 0
    @State private var lastMascotPokeAt = 0.0
    @State private var petReactAt: [Int: Double] = [:]
    @State private var moonReactAt: Double?

    var body: some View {
        let config = store.snapshot()
        let reactions = SleepyReactions(mascotAt: mascotReactAt, mascotPokes: mascotPokes, petAt: petReactAt, moonAt: moonReactAt)
        return GeometryReader { geo in
            ZStack {
                RadialGradient(
                    colors: SleepyPalette.glowColors(for: config),
                    center: .center,
                    startRadius: 0,
                    endRadius: 950
                )
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    // Sample the census + status here (main-actor view-builder
                    // context), never inside the Canvas renderer (which may run
                    // off-main, and runs once per display).
                    let agents = config.showPets ? agentCensus.sample(at: t) : SleepyAgentCounts()
                    let status = config.showStatus ? statusProvider.sample(at: t) : SleepyStatusSample(batteryLevel: nil, charging: false, wifiBars: nil)
                    Canvas { context, size in
                        draw(in: &context, size: size, time: t, config: config, agents: agents, status: status, reactions: reactions)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    handleTap(at: value.location, size: geo.size, config: config)
                })
                bottomBar(config: config)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .topLeading) { keepAwakeBadge(config: config).padding(26) }
        }
        .ignoresSafeArea()
        .task { powerUIState.isOn = await power.isLowPowerOn() }
    }

    // MARK: - Poke handling (easter eggs)

    private func handleTap(at location: CGPoint, size: CGSize, config: SleepyModeConfig) {
        let now = Date().timeIntervalSinceReferenceDate
        let pixel = max(2, (min(size.width, size.height) / 48).rounded())

        if config.showPets {
            let counts = agentCensus.sample(at: now)
            for frame in petFrames(size: size, pixel: pixel, time: now, counts: counts).reversed() {
                if frame.rect.insetBy(dx: -8, dy: -8).contains(location) {
                    petReactAt[frame.index] = now
                    return
                }
            }
        }
        if mascotRect(size: size, pixel: pixel).contains(location) {
            mascotPokes = (now - lastMascotPokeAt < 1.4) ? mascotPokes + 1 : 1
            lastMascotPokeAt = now
            mascotReactAt = now
            return
        }
        if config.showMoon, moonRect(size: size, pixel: pixel).insetBy(dx: -10, dy: -10).contains(location) {
            moonReactAt = now
            return
        }
        // Missed everything: wake (casual) or prompt Touch ID / password (locked).
        SleepyModeController.shared.toggle()
    }

    private func mascotRect(size: CGSize, pixel: CGFloat) -> CGRect {
        let center = CGPoint(x: (size.width / 2).rounded(), y: (size.height * 0.48).rounded())
        let half = 8.5 * pixel
        return CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2)
    }

    private func moonRect(size: CGSize, pixel: CGFloat) -> CGRect {
        let moonPixel = max(2, (pixel * 0.9).rounded())
        let origin = CGPoint(x: (size.width * 0.15).rounded(), y: (size.height * 0.18).rounded())
        return CGRect(x: origin.x, y: origin.y, width: 5 * moonPixel, height: 5 * moonPixel)
    }

    /// Tells the user whether the Mac is actually being kept awake. If the power
    /// assertions could not be acquired, it says so (and to use the Mac's own
    /// settings) rather than falsely reassuring.
    private func keepAwakeBadge(config: SleepyModeConfig) -> some View {
        let accent = SleepyPalette.colors(for: config)["O"] ?? .white
        let tint: Color = keepingAwake ? accent : Color(red: 0.95, green: 0.62, blue: 0.30)
        return HStack(spacing: 7) {
            Image(systemName: keepingAwake ? "cup.and.saucer.fill" : "exclamationmark.triangle.fill")
            Text(keepingAwake
                ? String(localized: "sleepyMode.keepAwake", defaultValue: "Mac staying awake")
                : String(localized: "sleepyMode.keepAwake.failed", defaultValue: "Couldn't keep Mac awake — check Battery settings"))
        }
        .font(.system(size: 13, weight: .bold, design: .monospaced))
        .foregroundStyle(tint.opacity(keepingAwake ? 0.7 : 0.95))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(keepingAwake ? 0.08 : 0.16))
        .overlay(Rectangle().strokeBorder(tint.opacity(keepingAwake ? 0.22 : 0.5), lineWidth: 2))
    }

    private func bottomBar(config: SleepyModeConfig) -> some View {
        let accent = SleepyPalette.colors(for: config)["O"] ?? .white
        let hintText = String(localized: "sleepyMode.dismissHintCasual", defaultValue: "Press any key to wake (click the characters to play)")
        return VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 16) {
                Button {
                    SleepyModeController.shared.toggle()
                } label: {
                    Label(String(localized: "sleepyMode.button.exit", defaultValue: "Exit"), systemImage: "xmark")
                }
                .buttonStyle(SleepyPixelButtonStyle(tint: Color(red: 0.52, green: 0.30, blue: 0.40)))

                Button {
                    // The real macOS login lock — genuinely secure (Apple's), unlike
                    // the overlay. The screensaver stays up behind it as the backdrop.
                    let power = power
                    Task { await power.lockMacNow() }
                } label: {
                    Label(String(localized: "sleepyMode.button.lockMac", defaultValue: "Lock Mac"), systemImage: "lock.fill")
                }
                .buttonStyle(SleepyPixelButtonStyle(tint: Color(red: 0.34, green: 0.30, blue: 0.60)))

                Button {
                    let power = power
                    Task { await power.sleepDisplayNow() }
                } label: {
                    Label(String(localized: "sleepyMode.button.sleepDisplay", defaultValue: "Sleep Display"), systemImage: "moon.fill")
                }
                .buttonStyle(SleepyPixelButtonStyle(tint: Color(red: 0.28, green: 0.40, blue: 0.62)))

                Button {
                    // Gate on the shared MainActor UI state so overlapping clicks
                    // (from any display) can't issue concurrent privileged toggles,
                    // and every overlay computes the next action from one value.
                    // The runner does the blocking pmset/admin-prompt work off-main;
                    // this task just suspends on await.
                    guard !powerUIState.isBusy else { return }
                    powerUIState.isBusy = true
                    let turnOn = !powerUIState.isOn
                    let power = power
                    let ui = powerUIState
                    Task {
                        ui.isOn = await power.setLowPowerMode(turnOn)
                        ui.isBusy = false
                    }
                } label: {
                    Label(
                        powerUIState.isOn
                            ? String(localized: "sleepyMode.button.lowPowerOn", defaultValue: "Low Power: On")
                            : String(localized: "sleepyMode.button.lowPowerOff", defaultValue: "Low Power: Off"),
                        systemImage: powerUIState.isOn ? "leaf.fill" : "leaf"
                    )
                }
                .buttonStyle(SleepyPixelButtonStyle(tint: powerUIState.isOn ? Color(red: 0.24, green: 0.56, blue: 0.32) : Color(red: 0.30, green: 0.42, blue: 0.46)))
                .disabled(powerUIState.isBusy)
            }
            Spacer().frame(height: 50)
            Text(hintText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(accent.opacity(0.4))
                .padding(.bottom, 38)
        }
    }

    // MARK: - Scene

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double, config: SleepyModeConfig, agents: SleepyAgentCounts, status: SleepyStatusSample, reactions: SleepyReactions) {
        let palette = SleepyPalette.colors(for: config)
        let ink = SleepyPalette.ink(for: config)
        let s = min(size.width, size.height)
        let pixel = max(2, (s / 48).rounded())
        let center = CGPoint(x: (size.width / 2).rounded(), y: (size.height * 0.48).rounded())

        if config.showStars { drawStars(in: &ctx, size: size, pixel: pixel, time: t, palette: palette) }
        if config.showMoon { drawMoon(in: &ctx, size: size, pixel: pixel, time: t, palette: palette) }
        if config.showClock { drawClock(in: &ctx, size: size, pixel: pixel, time: t, color: palette["O"] ?? .white) }
        if config.showStatus { drawStatus(in: &ctx, size: size, pixel: pixel, status: status, color: palette["O"] ?? .white) }

        // Moon easter egg: a shooting star streaks past when you poke the moon.
        if config.showMoon, let start = reactions.moonAt {
            let age = t - start
            if age >= 0, age < 1.2 {
                drawShootingStar(in: &ctx, size: size, pixel: pixel, progress: age / 1.2, color: palette["O"] ?? .white)
            }
        }

        let breath = sin(t * 2 * .pi / 4.6)
        var bob = (breath * 1.4).rounded() * pixel

        // Mascot poke reaction: pops up, eyes spring open, hearts float out.
        var eyesForceOpen = false
        var heartProgress: Double?
        if let start = reactions.mascotAt {
            let age = t - start
            if age >= 0, age < 0.9 {
                let p = age / 0.9
                bob -= CGFloat(sin(p * .pi)) * 7 * pixel
                eyesForceOpen = true
                heartProgress = p
            }
        }

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
            drawFace(in: &ctx, origin: origin, pixel: pixel, breath: breath, time: t, ink: ink, forceOpen: eyesForceOpen)
            drawCmuxLogo(in: &ctx, center: center, mascotRows: rows.count, pixel: pixel, time: t, palette: palette)
        }

        if let p = heartProgress {
            let count = min(2 + reactions.mascotPokes, 9)
            drawHearts(in: &ctx, center: CGPoint(x: center.x, y: center.y - 7 * pixel + bob), pixel: pixel, progress: p, count: count, burst: reactions.mascotPokes >= 5)
        }

        if config.showZs {
            let zOrigin = config.mascot == .logoFace
                ? CGPoint(x: center.x + 9 * pixel, y: center.y - 7 * pixel + bob)
                : CGPoint(x: center.x + 7 * pixel, y: center.y - 6 * pixel + bob)
            drawSleepZs(in: &ctx, origin: zOrigin, pixel: pixel, time: t, palette: palette)
        }

        if config.showPets {
            drawPets(in: &ctx, size: size, pixel: pixel, time: t, counts: agents, reactions: reactions)
        }
    }

    // MARK: - Agent pets

    /// Positions of every pet at a given time. Shared by the renderer and the
    /// tap hit-test so they always agree. Pets ping-pong within the screen.
    private func petFrames(size: CGSize, pixel: CGFloat, time t: Double, counts: SleepyAgentCounts) -> [SleepyPetFrame] {
        guard counts.total > 0 else { return [] }
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
        add(counts.pi, Color(red: 0.70, green: 0.52, blue: 0.97))
        add(counts.other, Color(red: 1.0, green: 0.70, blue: 0.80))

        let petW = CGFloat(petWidthCells) * cell
        let left = 2 * cell
        let right = max(left, size.width - petW - 2 * cell)
        let track = max(1, Double(right - left))
        var frames: [SleepyPetFrame] = []
        for (i, color) in colors.enumerated() {
            let speed = Double(cell) * (4 + Double(i % 4) * 2)
            let offset = Double(i) * 0.31 * track
            let phase = (t * speed + offset).truncatingRemainder(dividingBy: 2 * track)
            let goingRight = phase < track
            let pos = goingRight ? phase : (2 * track - phase)
            let x = (left + CGFloat(pos)).rounded()
            let step = Int(t * 6 + Double(i)) % 2
            frames.append(SleepyPetFrame(
                rect: CGRect(x: x, y: baseline - 5 * cell, width: petW, height: 5 * cell),
                color: color, index: i, facingRight: goingRight, step: step, cell: cell
            ))
        }
        return frames
    }

    /// One walking pixel pet per open coding agent (Claude/Codex/OpenCode/pi).
    /// Poke one and it leaps with a sparkle.
    private func drawPets(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, time t: Double, counts: SleepyAgentCounts, reactions: SleepyReactions) {
        for frame in petFrames(size: size, pixel: pixel, time: t, counts: counts) {
            let cell = frame.cell
            var y = frame.rect.minY + (sin(t * 7 + Double(frame.index)) > 0.6 ? -cell : 0)
            if let start = reactions.petAt[frame.index] {
                let age = t - start
                if age >= 0, age < 0.6 {
                    y -= CGFloat(sin(age / 0.6 * .pi)) * 4 * cell
                    drawSparkle(in: &ctx, center: CGPoint(x: frame.rect.midX, y: y - 2 * cell), cell: cell, color: frame.color)
                }
            }
            drawPet(in: &ctx, x: frame.rect.minX, y: y, cell: cell, color: frame.color, step: frame.step, facingRight: frame.facingRight)
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

    // MARK: - Reaction effects (easter eggs)

    private static let heartGlyph: [String] = [
        ".X.X.",
        "XXXXX",
        "XXXXX",
        ".XXX.",
        "..X..",
    ]

    /// Hearts floating up out of the mascot when poked; a poked-5-times "burst"
    /// fans them in a ring.
    private func drawHearts(in ctx: inout GraphicsContext, center: CGPoint, pixel: CGFloat, progress p: Double, count: Int, burst: Bool) {
        let heartColor = Color(red: 1.0, green: 0.45, blue: 0.62)
        let heartPixel = max(2, (pixel * 0.4).rounded())
        let fade = sin(p * .pi)
        for i in 0..<max(1, count) {
            let angle: Double
            let reach: Double
            if burst {
                angle = -.pi / 2 + (Double(i) / Double(max(1, count - 1)) - 0.5) * 2.4
                reach = 9 * Double(pixel)
            } else {
                angle = -.pi / 2 + (Double(i % 3) - 1) * 0.5
                reach = 7 * Double(pixel)
            }
            let dist = reach * p
            let x = center.x + CGFloat(cos(angle) * dist)
            let y = center.y + CGFloat(sin(angle) * dist) - CGFloat(Double(i % 3)) * pixel
            drawSprite(in: &ctx, rows: Self.heartGlyph, palette: ["X": heartColor], origin: CGPoint(x: x.rounded(), y: y.rounded()), pixel: heartPixel, alpha: fade)
        }
    }

    /// A little four-point sparkle above a poked pet.
    private func drawSparkle(in ctx: inout GraphicsContext, center: CGPoint, cell: CGFloat, color: Color) {
        for arm in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
            ctx.fill(Path(CGRect(x: center.x + CGFloat(arm.0) * cell, y: center.y + CGFloat(arm.1) * cell, width: cell, height: cell)), with: .color(color.opacity(0.9)))
        }
        ctx.fill(Path(CGRect(x: center.x, y: center.y, width: cell, height: cell)), with: .color(.white))
    }

    /// A shooting star streaking across the sky (moon easter egg).
    private func drawShootingStar(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, progress p: Double, color: Color) {
        let startX = size.width * 0.20
        let startY = size.height * 0.16
        let dx = size.width * 0.55
        let dy = size.height * 0.18
        let headX = startX + CGFloat(p) * dx
        let headY = startY + CGFloat(p) * dy
        let fade = sin(p * .pi)
        for trail in 0..<6 {
            let tp = max(0, p - Double(trail) * 0.03)
            let tx = startX + CGFloat(tp) * dx
            let ty = startY + CGFloat(tp) * dy
            let sz = max(2, pixel - CGFloat(trail))
            ctx.fill(Path(CGRect(x: tx, y: ty, width: sz, height: sz)), with: .color(color.opacity(fade * (1 - Double(trail) / 6))))
        }
        ctx.fill(Path(CGRect(x: headX, y: headY, width: pixel, height: pixel)), with: .color(.white.opacity(fade)))
    }

    // MARK: - Grid mascot face (eyes/mouth on top of the sprite)

    private func drawFace(in ctx: inout GraphicsContext, origin: CGPoint, pixel: CGFloat, breath: Double, time t: Double, ink: Color, forceOpen: Bool = false) {
        let cells = (forceOpen || eyePeek(t)) ? SleepyArt.openEyes : SleepyArt.closedEyes
        for cell in cells { fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink) }
        for cell in SleepyArt.mouthTop { fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink) }
        if breath > 0.1 {
            for cell in SleepyArt.mouthOpen { fillCell(in: &ctx, origin: origin, pixel: pixel, col: cell.0, row: cell.1, color: ink) }
        }
    }

    /// logoFace: cmux chevron `>` as the left eye, a `-` dash as the (winking)
    /// right eye, blush, and a small sleepy mouth.
    private func drawLogoFace(in ctx: inout GraphicsContext, center: CGPoint, pixel: CGFloat, breath: Double, time t: Double, palette: [Character: Color], ink: Color) {
        let eyePixel = max(2, (pixel * 0.6).rounded())
        let chevW = SleepyArt.cmuxLogo.first?.count ?? 11
        let chevH = SleepyArt.cmuxLogo.count
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
        let hour = comps.hour ?? 0, minute = comps.minute ?? 0, month = comps.month ?? 0, day = comps.day ?? 0

        let timePixel = max(2, (pixel * 0.9).rounded())
        let datePixel = max(2, (pixel * 0.5).rounded())
        let cx = (size.width / 2).rounded()
        // Drawn directly from digit components — no per-frame string allocation.
        drawGlyphPair(in: &ctx, a: hour, separator: SleepyArt.colonGlyph, b: minute, centerX: cx, top: (size.height * 0.10).rounded(), pixel: timePixel, color: color)
        drawGlyphPair(in: &ctx, a: month, separator: SleepyArt.slashGlyph, b: day, centerX: cx, top: (size.height * 0.10 + 7 * Double(timePixel) + 4 * Double(datePixel)).rounded(), pixel: datePixel, color: color.opacity(0.7))
    }

    /// Draws a zero-padded `aa<sep>bb` (e.g. "17:34") centered, glyph by glyph.
    private func drawGlyphPair(in ctx: inout GraphicsContext, a: Int, separator: [String], b: Int, centerX: CGFloat, top: CGFloat, pixel: CGFloat, color: Color) {
        let digitW = 3
        let sepW = separator.first?.count ?? 1
        let totalCols = digitW * 4 + sepW + 4   // four digits + separator + four gaps
        var x = (centerX - CGFloat(totalCols) / 2 * pixel).rounded()
        func glyph(_ rows: [String], _ width: Int) {
            drawSprite(in: &ctx, rows: rows, palette: ["#": color], origin: CGPoint(x: x, y: top), pixel: pixel)
            x += CGFloat(width + 1) * pixel
        }
        glyph(SleepyArt.digitGlyphs[(a / 10) % 10], digitW)
        glyph(SleepyArt.digitGlyphs[a % 10], digitW)
        glyph(separator, sepW)
        glyph(SleepyArt.digitGlyphs[(b / 10) % 10], digitW)
        glyph(SleepyArt.digitGlyphs[b % 10], digitW)
    }

    private func drawStatus(in ctx: inout GraphicsContext, size: CGSize, pixel: CGFloat, status: SleepyStatusSample, color: Color) {
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
        // Border — paint each cell exactly once (corners drawn by the top/bottom
        // rows only) so they don't stack to a brighter alpha.
        for col in 0..<cols { put(col, 0, frame); put(col, rows - 1, frame) }
        for row in 1..<(rows - 1) { put(0, row, frame); put(cols - 1, row, frame) }
        // Terminal nub (a tidy 2-cell cap, vertically centered).
        put(cols, rows / 2 - 1, frame); put(cols, rows / 2, frame)
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
