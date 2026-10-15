import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxTheme
import Testing

/// Leo, 2026-10-14: the tooltip is frosted glass (a strong blur under a tint dense enough that the
/// text reads over anything, a one-device-pixel rim, a small tight shadow; the opaque popup
/// surface under Reduce Transparency), one surface for the app and its pages (`TooltipSurface`).
/// The first of a group fades in over the fade-in token (120 ms) rising 2 pt, a warm neighbor's is
/// there at once with no fade, and it fades out quicker (80 ms). Reduce Motion keeps the fade and
/// drops the rise.
@MainActor @Suite(.serialized) struct TooltipSurfaceTests {
    /// Light and dark themes, plain and colored, the low-contrast ones included.
    static let themes = [
        ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x000000)),
        ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F)),
        ThemeInput(background: ThemeRGB(hex: 0xFDF6E3), foreground: ThemeRGB(hex: 0x657B83)),
        ThemeInput(background: ThemeRGB(hex: 0xEEEEEE), foreground: ThemeRGB(hex: 0x333333)),
        ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4)),
        ThemeInput(background: ThemeRGB(hex: 0x282A36), foreground: ThemeRGB(hex: 0xF8F8F2)),
        ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496)),
        ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF), backgroundOpacity: 0.6),
    ]

    /// The blur only averages what is under the tooltip, so the worst a backdrop can do is pure
    /// black or pure white: over both, the text keeps 4.5:1, on the glass and on the opaque
    /// Reduce Transparency fallback.
    @Test func theTextKeepsFourAndAHalfToOneOverBlackAndWhite() {
        let black = ThemeRGB(hex: 0x000000)
        let white = ThemeRGB(hex: 0xFFFFFF)
        for input in Self.themes {
            let tokens = ThemeTokens.derive(from: input)
            let surface = TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
            let ink = tokens.textPrimary.withAlpha(1)
            let name = "\(input.background) \(tokens.isDark ? "dark" : "light")"
            #expect(surface.tint.alpha >= TooltipSurface.minimumTintAlpha && surface.tint.alpha <= 1, "\(name)")
            for backdrop in [black, white] {
                let glass = ink.contrast(with: surface.tint.composited(over: backdrop))
                #expect(glass >= ThemeTokens.minimumTextContrast, "\(name) over \(backdrop): \(glass)")
            }
            // Reduce Transparency: the opaque popup surface.
            #expect(surface.fill.alpha == 1)
            let opaque = ink.contrast(with: surface.fill)
            #expect(opaque >= ThemeTokens.minimumTextContrast, "\(name) opaque: \(opaque)")
        }
        // A plain light and a plain dark theme are glass, not the opaque fill in disguise.
        for input in [Self.themes[0], Self.themes[4]] {
            let surface = TooltipSurface(ThemeTokens.derive(from: input), lift: ChromeTunables.opaqueOverlayLift.value)
            #expect(surface.tint.alpha < 1, "\(input.background): the tint is opaque")
        }
    }

    /// Pages get the same tint (`--cmux-tooltip-tint`).
    @Test func pagesGetTheSameTint() throws {
        let tokens = ThemeTokens.derive(from: Self.themes[4])
        let tint = try #require(WebTheme(tokens, surface: .internalPage, backgrounds: .none).variables["--cmux-tooltip-tint"])
        #expect(tint == WebTheme.css(TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value).tint))
    }

    // MARK: The panel

    /// Fleet hosts with no display drop layer animations (a window with no screen).
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    private static func toolbar(clock: ManualClock) throws -> (NSWindow, [ChromeIconButton], TooltipPresenter, ThemeScope) {
        _ = NSApplication.shared
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Stress Purple")), input: themes[5], animated: false)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let buttons = ["Back", "Forward", "Reload"].enumerated().map { index, label in
            let button = ChromeIconButton(icon: .navPreviousMatch, label: label, action: nil, target: nil)
            button.frame = NSRect(x: 10 + CGFloat(index) * 30, y: 18, width: 24, height: 24)
            window.contentView?.addSubview(button)
            return button
        }
        scope.root(try #require(window.contentView))
        window.orderFrontRegardless()
        let presenter = TooltipPresenter(clock: clock)
        presenter.timing = .standard
        // The surface's animations hold still, as the hover delay does on the manual clock: the
        // test reads the fade the tooltip starts, however long a loaded host takes to get to it
        // (the macOS 27 lane, 2026-10-14, read it after it had finished and been removed).
        presenter.panel.surface.layer?.speed = 0
        return (window, buttons, presenter, scope)
    }

    private static func tracker(_ view: NSView) throws -> TooltipTracker {
        try #require(TooltipTracker.whole(of: view))
    }

    private static func settle(until done: @escaping () -> Bool) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Rests on `button` past the delay until its tooltip shows.
    /// `watch` stops at the show: only a change before it can have reached the tooltip.
    private static func rest(on button: NSView, _ presenter: TooltipPresenter, _ clock: ManualClock,
                             watch: OverrideWatch? = nil) async throws {
        presenter.enter(try tracker(button))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(500))
        try await settle(until: { presenter.shown != nil })
        watch?.stop()
        try #require(presenter.shown != nil, "no tooltip after the delay")
        // A loaded host can take this long to come back to the test after the tooltip shows (the
        // macOS 27 lane, 2026-10-14, runs every suite in one process): longer than the fade in.
        // What the test reads must not depend on how soon it gets to read it.
        try await Task.sleep(for: .milliseconds(300))
    }

    /// `animation`'s value `ms` after it starts: its from-to blend at the timing curve's progress.
    private static func value(of animation: CABasicAnimation, at ms: Double) throws -> Double {
        let from = try #require((animation.fromValue as? NSNumber)?.doubleValue)
        let to = try #require((animation.toValue as? NSNumber)?.doubleValue)
        let time = min(max(ms / 1000 / animation.duration, 0), 1)
        return from + (to - from) * progress(animation.timingFunction, at: time)
    }

    /// The cubic-bezier timing curve's output at input `x` (bisection on the curve's x).
    private static func progress(_ function: CAMediaTimingFunction?, at x: Double) -> Double {
        guard let function else { return x }
        var points = [Float](repeating: 0, count: 2)
        var c1 = CGPoint.zero
        var c2 = CGPoint.zero
        points.withUnsafeMutableBufferPointer { buffer in
            function.getControlPoint(at: 1, values: buffer.baseAddress!)
            c1 = CGPoint(x: CGFloat(buffer[0]), y: CGFloat(buffer[1]))
            function.getControlPoint(at: 2, values: buffer.baseAddress!)
            c2 = CGPoint(x: CGFloat(buffer[0]), y: CGFloat(buffer[1]))
        }
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(mid, Double(c1.x), Double(c2.x)) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, Double(c1.y), Double(c2.y))
    }

    /// What the panel looks like when an expected animation is missing (macOS 27 lane, 2026-10-14).
    private static func diagnose(_ presenter: TooltipPresenter, _ layer: CALayer, _ before: CALayer?) -> String {
        let rise = layer.animation(forKey: "transform.translation.y")
        let age = rise.map { CACurrentMediaTime() - $0.beginTime }
        return "shown \(presenter.shown?.text ?? "nil"), visible \(presenter.panel.isVisible), fadingOut \(presenter.panel.isFadingOut), "
            + "same layer \(before === layer), keys \(layer.animationKeys() ?? []), rise age \(age.map { "\($0)" } ?? "nil"), "
            + "opacity \(layer.opacity), presented \(layer.presentation()?.opacity ?? -1), fadeIn \(Motion.duration(.fadeIn)), "
            + "speed \(Motion.speed), reduce \(Motion.reduceMotion), active \(NSApp.isActive), screens \(NSScreen.screens.count)"
    }

    /// Whether another suite set or cleared `Motion.reduceMotionOverride` while a test ran. The
    /// override is process-global, and a lane that runs every suite in one process (the macOS 27
    /// lane, 2026-10-14) lets another suite change it while this one awaits the hover delay; the
    /// tooltip then reads that, not this test's value.
    /// The change is posted on the main actor, where the test reads `changed`.
    nonisolated final class OverrideWatch: @unchecked Sendable {
        private(set) var changed = false
        private var token: (any NSObjectProtocol)?
        init(_ name: Notification.Name) {
            token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.changed = true
            }
        }
        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }

    /// Whether the tooltip read Reduce Motion when it showed, from its fade's length (Reduce Motion
    /// caps a fade at one crossfade): the same gate the product used, whatever the override says now.
    private static func readReduceMotion(_ fade: CABasicAnimation) throws -> Bool {
        let on = MotionPolicy(speed: Motion.speed, reduceMotion: true).duration(.fadeIn)
        let off = MotionPolicy(speed: Motion.speed, reduceMotion: false).duration(.fadeIn)
        try #require(on != off, "Reduce Motion does not change the fade in at speed \(Motion.speed)")
        return abs(fade.duration - on) < 0.0001
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func theFirstTooltipFadesInRisingAndAWarmNeighborsIsThereAtOnce() async throws {
        Motion.reduceMotionOverride = false
        // Another suite's window mid-resize would drop the rise (`Motion.isLiveResizing`).
        Motion.liveResizeOverride = false
        let watch = OverrideWatch(Motion.reduceMotionDidChange)
        defer {
            watch.stop()
            Motion.reduceMotionOverride = nil
            Motion.liveResizeOverride = nil
        }
        let clock = ManualClock()
        let (window, buttons, presenter, _) = try Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        try #require(window.screen != nil, "the window has no screen")
        try #require(Motion.duration(.fadeIn) > 0, "fades are off on this host")
        let before = presenter.panel.surface.layer
        try await Self.rest(on: buttons[0], presenter, clock, watch: watch)
        let layer = try #require(presenter.panel.surface.layer)
        let fade = try #require(layer.animation(forKey: "opacity") as? CABasicAnimation,
                                "the first tooltip did not fade in: \(Self.diagnose(presenter, layer, before))")
        if try Self.readReduceMotion(fade) {
            // Another suite turned Reduce Motion on under this one: the fade stays and the rise goes;
            // the rest of the checks need Reduce Motion off and do not run.
            #expect(watch.changed, "the tooltip read Reduce Motion on though nothing turned it on")
            #expect(layer.animation(forKey: "transform.translation.y") == nil, "it rose under Reduce Motion")
            return
        }
        let rise = try #require(layer.animation(forKey: "transform.translation.y") as? CABasicAnimation,
                                "the first tooltip did not rise")
        #expect(fade.duration == MotionPolicy(speed: Motion.speed, reduceMotion: false).duration(.fadeIn))
        #expect(fade.duration >= 0.1 && fade.duration <= 0.15, "fade in \(fade.duration) s")
        #expect(abs(try Self.value(of: fade, at: 0)) < 0.01)
        let midway = try Self.value(of: fade, at: 75)
        #expect(midway > 0.5 && midway < 1, "opacity \(midway) at 75 ms")
        #expect(abs(try Self.value(of: fade, at: 150) - 1) < 0.01)
        #expect(abs(try Self.value(of: rise, at: 0) + Double(TooltipPanel.rise)) < 0.01)
        #expect(TooltipPanel.rise > 0 && TooltipPanel.rise <= 2)
        #expect(abs(try Self.value(of: rise, at: 150)) < 0.01)

        // Warm: the neighbor's text at once, no fade again.
        presenter.exit(try Self.tracker(buttons[0]))
        presenter.enter(try Self.tracker(buttons[1]))
        #expect(presenter.shown?.text == "Forward")
        #expect(layer.animation(forKey: "opacity") == nil, "a warm neighbor's tooltip faded in again")
        #expect(layer.opacity == 1)

        // Away: it fades out, quicker than it came.
        presenter.exit(try Self.tracker(buttons[1]))
        #expect(presenter.shown == nil)
        let out = try #require(layer.animation(forKey: "opacity") as? CABasicAnimation, "the tooltip vanished with no fade")
        #expect(out.duration == Motion.duration(.fadeOut))
        #expect(out.duration < fade.duration)
        #expect((out.toValue as? NSNumber)?.doubleValue == 0)
        #expect(abs(try Self.value(of: out, at: out.duration * 1000)) < 0.01)
        #expect(presenter.panel.isFadingOut)

        // A click puts it away at once, as AppKit's: no fade over the menu the click opens.
        presenter.enter(try Self.tracker(buttons[2]))
        #expect(presenter.shown?.text == "Reload", "a tooltip within the warm time waited")
        presenter.dismiss()
        #expect(!presenter.panel.isVisible, "a dismissed tooltip lingered")
        #expect(!presenter.panel.isFadingOut)
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func underReduceMotionTheTooltipFadesWithNoRise() async throws {
        Motion.reduceMotionOverride = true
        let watch = OverrideWatch(Motion.reduceMotionDidChange)
        defer {
            watch.stop()
            Motion.reduceMotionOverride = nil
        }
        let clock = ManualClock()
        let (window, buttons, presenter, _) = try Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        try #require(window.screen != nil, "the window has no screen")
        try await Self.rest(on: buttons[0], presenter, clock, watch: watch)
        let layer = try #require(presenter.panel.surface.layer)
        let fade = try #require(layer.animation(forKey: "opacity") as? CABasicAnimation, "no fade under Reduce Motion")
        #expect(fade.duration > 0)
        // The rise follows the gate the tooltip read; it reads Reduce Motion off only when another
        // suite cleared the override under this one.
        let reduced = try Self.readReduceMotion(fade)
        #expect(reduced || watch.changed, "the tooltip read Reduce Motion off though nothing turned it off")
        #expect((layer.animation(forKey: "transform.translation.y") == nil) == reduced,
                "the rise does not follow Reduce Motion (read \(reduced ? "on" : "off"))")
    }

    @Test func theSurfaceIsFrostedGlassOrOpaqueUnderReduceTransparency() async throws {
        defer { ReduceTransparency.shared.override = nil }
        for reduce in [false, true] {
            ReduceTransparency.shared.override = reduce
            let clock = ManualClock()
            let (window, buttons, presenter, scope) = try Self.toolbar(clock: clock)
            defer {
                presenter.dismiss()
                window.orderOut(nil)
            }
            try await Self.rest(on: buttons[0], presenter, clock)
            let panel = presenter.panel
            let surface = TooltipSurface(scope.tokens, lift: ChromeTunables.opaqueOverlayLift.value)
            let fill = try #require(panel.tint.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
            let want = (reduce ? surface.fill : surface.tint).nsColor.usingColorSpace(.sRGB)
            #expect(abs(fill.alphaComponent - (want?.alphaComponent ?? -1)) < 0.01, "reduce \(reduce)")
            #expect(panel.blur.isHidden == reduce, "reduce \(reduce): blur")
            if !reduce {
                #expect(panel.blur.blendingMode == .behindWindow)
                #expect(panel.blur.state == .active)
            }
            // A one-device-pixel rim and a small tight shadow, no window shadow.
            // The screen the tooltip shows on, or the window's own scale on a host with no screen.
            let scale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
            #expect(abs((panel.tint.layer?.borderWidth ?? 0) - 1 / scale) < 0.001)
            #expect(!panel.hasShadow)
            #expect(panel.surface.layer?.shadowOpacity == Float(PopupStyle.elevation1.alpha))
            #expect((panel.surface.layer?.shadowRadius ?? 99) <= 2)
        }
    }
}
