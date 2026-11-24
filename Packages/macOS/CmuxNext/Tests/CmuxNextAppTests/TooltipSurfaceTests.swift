import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CmuxTheme
import Testing
import CmuxNextWakeupsTestSupport

/// Leo, 2026-10-14: the tooltip is frosted glass (a strong blur under a tint dense enough that the
/// text reads over anything, a one-device-pixel rim, a small tight shadow; the opaque popup
/// surface under Reduce Transparency), one surface for the app and its pages (`TooltipSurface`).
/// The first of a group waits the hover delay and shows in one frame, a warm neighbor's is there at
/// once, and it goes in one frame (Lawrence 2026-11-20: one tooltip everywhere, as the pages').
@MainActor @Suite(.serialized, .closesItsWindows) struct TooltipSurfaceTests {
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
    /// Reduce Transparency fallback. Every theme's tint is glass, never the opaque fill in
    /// disguise, and these themes' text reads on it as the theme draws it, unless no glass tint
    /// can carry the theme's own text: then the ink is that text walked toward its extreme
    /// (`TooltipSurface.legible`). Solarized light's text is one since the lighter light-theme row
    /// fills (21f9d43e937, #39956) left its derived text at #596C73, which misses 4.5:1 over the
    /// densest white tint on black.
    @Test func theTextKeepsFourAndAHalfToOneOverBlackAndWhite() {
        let black = ThemeRGB(hex: 0x000000)
        let white = ThemeRGB(hex: 0xFFFFFF)
        #expect(TooltipSurface.maximumTintAlpha < 1)
        for input in Self.themes {
            let tokens = ThemeTokens.derive(from: input)
            let surface = TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
            let name = "\(input.background) \(tokens.isDark ? "dark" : "light")"
            let themeInk = tokens.textPrimary.withAlpha(1)
            if surface.ink != themeInk {
                let fill = tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
                let lightInk = themeInk.relativeLuminance >= fill.relativeLuminance
                let pole: ThemeRGB = lightInk ? .white : .black
                #expect(TooltipSurface.tintAlpha(fill: lightInk ? .black : .white, ink: themeInk) == nil,
                        "\(name): the ink moved off the theme's text though a glass tint carries it")
                #expect((1...100).contains { themeInk.mixed(toward: pole, Double($0) / 100) == surface.ink },
                        "\(name): the ink \(surface.ink) is not the theme's text walked toward its extreme")
            }
            #expect(surface.tint.alpha >= TooltipSurface.minimumTintAlpha
                && surface.tint.alpha <= TooltipSurface.maximumTintAlpha, "\(name): the tint is \(surface.tint.alpha)")
            // Native, and as pages get them (`--cmux-tooltip-ink` and `-tint`, 8-bit channels): Codex
            // review of #23970, Solarized light read 4.500:1 native but 4.485:1 once rounded.
            let variables = WebTheme(tokens, surface: .internalPage, backgrounds: .none).variables
            #expect(variables["--cmux-tooltip-ink"] == WebTheme.css(WebTheme.cssRounded(surface.ink)), "\(name)")
            #expect(variables["--cmux-tooltip-tint"] == WebTheme.css(WebTheme.cssRounded(surface.tint)), "\(name)")
            let page = (ink: WebTheme.cssRounded(surface.ink), tint: WebTheme.cssRounded(surface.tint))
            for backdrop in [black, white] {
                let glass = surface.ink.contrast(with: surface.tint.composited(over: backdrop))
                #expect(glass >= ThemeTokens.minimumTextContrast, "\(name) over \(backdrop): \(glass)")
                let pageGlass = page.ink.contrast(with: page.tint.composited(over: backdrop))
                #expect(pageGlass >= ThemeTokens.minimumTextContrast, "\(name) page over \(backdrop): \(pageGlass)")
            }
            // Reduce Transparency: the opaque popup surface.
            #expect(surface.fill.alpha == 1)
            let opaque = surface.ink.contrast(with: surface.fill)
            #expect(opaque >= ThemeTokens.minimumTextContrast, "\(name) opaque: \(opaque)")
        }
    }

    /// Codex review of #23970: Solarized dark (#002B36 under #839496) found no translucent alpha
    /// that kept its text at 4.5:1 and fell back to the solid popup surface, an opaque card. A
    /// theme whose text does not read on its own tint walks the tint away from the text (then the
    /// text toward its extreme), so the tooltip stays glass and the text keeps 4.5:1 over pure
    /// black and pure white, and 4.5:1 over the opaque fill Reduce Transparency draws; the colors
    /// the reviews named, and fills and inks with next to no contrast, included.
    @Test func aLowContrastThemesTooltipIsStillGlassAndReads() {
        let solarized = ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496))
        let tokens = ThemeTokens.derive(from: solarized)
        let themed = TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
        // Reduce Transparency's opaque surface still carries the ink.
        #expect(themed.ink.contrast(with: themed.fill) >= ThemeTokens.minimumTextContrast)
        let pairs: [(String, TooltipSurface)] = [
            ("Solarized dark", themed),
            ("#002B36 under #839496", TooltipSurface(fill: ThemeRGB(hex: 0x002B36), ink: ThemeRGB(hex: 0x839496))),
            ("#0A333E under #839496", TooltipSurface(fill: ThemeRGB(hex: 0x0A333E), ink: ThemeRGB(hex: 0x839496))),
            ("#000000 under #777777", TooltipSurface(fill: ThemeRGB(hex: 0x000000), ink: ThemeRGB(hex: 0x777777))),
            ("#898989 under #FFFFFF", TooltipSurface(fill: ThemeRGB(hex: 0x898989), ink: ThemeRGB(hex: 0xFFFFFF))),
            ("#FDF7E7 under #93A1A1", TooltipSurface(fill: ThemeRGB(hex: 0xFDF7E7), ink: ThemeRGB(hex: 0x93A1A1))),
            ("#808080 under #808080", TooltipSurface(fill: ThemeRGB(hex: 0x808080), ink: ThemeRGB(hex: 0x808080))),
        ]
        for (name, surface) in pairs {
            #expect(surface.tint.alpha >= TooltipSurface.minimumTintAlpha && surface.tint.alpha < 1
                && surface.tint.alpha <= TooltipSurface.maximumTintAlpha, "\(name): the tint is \(surface.tint.alpha), not glass")
            for backdrop in [ThemeRGB(hex: 0x000000), ThemeRGB(hex: 0xFFFFFF)] {
                let contrast = surface.ink.contrast(with: surface.tint.composited(over: backdrop))
                #expect(contrast >= ThemeTokens.minimumTextContrast, "\(name) over \(backdrop): \(contrast)")
            }
            // Reduce Transparency draws the same ink over the opaque fill (Codex review of #23970:
            // #839496 over #0A333E kept the theme's ink and read 4.27:1 there).
            let opaque = surface.ink.contrast(with: surface.fill)
            #expect(opaque >= ThemeTokens.minimumTextContrast, "\(name) opaque: \(opaque)")
            let page = WebTheme.cssRounded(surface.ink).contrast(with: WebTheme.cssRounded(surface.fill))
            #expect(page >= ThemeTokens.minimumTextContrast, "\(name) opaque page: \(page)")
        }
        // That pair's ink moves toward white, never darker, and its fill is untouched.
        let review = TooltipSurface(fill: ThemeRGB(hex: 0x0A333E), ink: ThemeRGB(hex: 0x839496))
        #expect(review.fill == ThemeRGB(hex: 0x0A333E))
        #expect(review.ink != ThemeRGB(hex: 0x839496) && review.ink.relativeLuminance > ThemeRGB(hex: 0x839496).relativeLuminance)
    }

    /// Pages get the same tint (`--cmux-tooltip-tint`).
    @Test func pagesGetTheSameTint() throws {
        let tokens = ThemeTokens.derive(from: Self.themes[4])
        let variables = WebTheme(tokens, surface: .internalPage, backgrounds: .none).variables
        let surface = TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
        #expect(try #require(variables["--cmux-tooltip-tint"]) == WebTheme.css(surface.tint))
        #expect(try #require(variables["--cmux-tooltip-ink"]) == WebTheme.css(surface.ink))
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
            // Back has a shortcut: its keys show on the tooltip's keycap.
            if index == 0 { button.themedToolTipShortcut = "⌘[" }
            return button
        }
        scope.root(try #require(window.contentView))
        window.orderFrontRegardless()
        let presenter = TooltipPresenter(clock: clock)
        presenter.timing = .standard
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
    private static func rest(on button: NSView, _ presenter: TooltipPresenter, _ clock: ManualClock) async throws {
        presenter.enter(try tracker(button))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(500))
        try await settle(until: { presenter.shown != nil })
        try #require(presenter.shown != nil, "no tooltip after the delay")
    }

    /// The first tooltip waits the hover delay, then shows in one frame: no fade, no rise (Lawrence 2026-11-20: one
    /// tooltip everywhere; the pages' tooltips already show in one frame, Leo 2026-11-11). A warm neighbor's is
    /// there at once, leaving puts it away at once, and so does a click.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() },
          arguments: [false, true])
    func theFirstTooltipWaitsThenShowsInOneFrameAndAWarmNeighborsIsThereAtOnce(reduceMotion: Bool) async throws {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let clock = ManualClock()
        let (window, buttons, presenter, _) = try Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.closeAfterTest()
        }
        try #require(window.screen != nil, "the window has no screen")
        presenter.enter(try Self.tracker(buttons[0]))
        #expect(presenter.shown == nil, "the first tooltip did not wait the hover delay")
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(500))
        try await Self.settle(until: { presenter.shown != nil })
        try #require(presenter.shown != nil, "no tooltip after the delay")
        let layer = try #require(presenter.panel.surface.layer)
        #expect(presenter.panel.isVisible)
        #expect(layer.animation(forKey: "opacity") == nil, "reduce \(reduceMotion): the tooltip faded in")
        #expect(layer.animation(forKey: "transform.translation.y") == nil, "reduce \(reduceMotion): the tooltip rose")
        #expect(layer.opacity == 1)

        // Warm: the neighbor's text at once.
        presenter.exit(try Self.tracker(buttons[0]))
        presenter.enter(try Self.tracker(buttons[1]))
        #expect(presenter.shown?.text == "Forward")
        #expect(layer.animation(forKey: "opacity") == nil, "a warm neighbor's tooltip faded in")

        // Away: gone in the same frame.
        presenter.exit(try Self.tracker(buttons[1]))
        #expect(presenter.shown == nil)
        #expect(!presenter.panel.isVisible, "the tooltip lingered after the pointer left")
        #expect(layer.animation(forKey: "opacity") == nil, "the tooltip faded out")

        // A click puts it away at once, as AppKit's.
        presenter.enter(try Self.tracker(buttons[2]))
        #expect(presenter.shown?.text == "Reload", "a tooltip within the warm time waited")
        presenter.dismiss()
        #expect(!presenter.panel.isVisible, "a dismissed tooltip lingered")
    }

    /// Leo 2026-10-21: "WHERE IS THE GLASS EVERYWHERE, all these hover tooltips and hover previews".
    /// The tooltip is the shared overlay glass the hover cards draw (`Glass.makeOverlayPanel`), in
    /// the hovered view's theme, never a card fill; the opaque popup surface only under Reduce
    /// Transparency.
    /// The glass is the hover surface setting's `glass` value (Leo 2026-11-24 named it: "wack ass glass";
    /// the solid default is `HoverSurfaceStaysPutTests`).
    @Test func theSurfaceIsTheSharedGlassOrOpaqueUnderReduceTransparency() async throws {
        let hoverStore = TunableStore.shared
        hoverStore.register([HoverSurfaceLook.tunable.descriptor])
        if !hoverStore.isActive { hoverStore.activate(file: nil) }
        let hoverBefore = hoverStore.overrides[HoverSurfaceLook.tunable.key]
        hoverStore.set(HoverSurfaceLook.tunable.key, .choice(HoverSurfaceLook.glass.rawValue))
        defer {
            ReduceTransparency.shared.override = nil
            hoverStore.set(HoverSurfaceLook.tunable.key, hoverBefore)
        }
        for reduce in [false, true] {
            ReduceTransparency.shared.override = reduce
            let clock = ManualClock()
            let (window, buttons, presenter, scope) = try Self.toolbar(clock: clock)
            defer {
                presenter.dismiss()
                window.closeAfterTest()
            }
            try await Self.rest(on: buttons[0], presenter, clock)
            let panel = presenter.panel
            #expect(panel.glass.themeScope === scope.fullStrength, "reduce \(reduce): not in the view's theme")
            #expect(!panel.glass.isCard, "reduce \(reduce): the opaque card fill on the tooltip's glass")
            #expect((panel.glass.material == .opaque) == reduce, "reduce \(reduce): material \(panel.glass.material)")
            #expect(panel.glass.samplesBehindWindow)
            #expect(panel.glass.frame == panel.surface.bounds)
            // The legibility tint over the glass, under the labels: translucent, and the text keeps
            // 4.5:1 over it on pure black and pure white; clear on the opaque surface.
            let tint = try Self.tint(of: panel)
            if reduce {
                #expect(tint.alpha == 0, "reduce: a tint over the opaque surface")
            } else {
                #expect(tint.alpha > 0 && tint.alpha < 1, "the legibility tint is \(tint.alpha): not glass")
                let contrast = TooltipSurface.worstContrast(ink: try Self.ink(of: panel), tint: tint)
                #expect(contrast >= ThemeTokens.minimumTextContrast, "the text reads \(contrast):1 over black or white")
            }
            #expect(panel.legibility.superview === panel.glass.contentView)
            #expect(panel.legibility.frame == panel.surface.bounds)
            #expect(panel.content.superview === panel.glass.contentView && panel.text.superview === panel.content)
            // A small tight shadow, no window shadow.
            #expect(!panel.hasShadow)
            #expect(panel.surface.layer?.shadowOpacity == Float(PopupStyle.elevation1.alpha))
            #expect((panel.surface.layer?.shadowRadius ?? 99) <= 2)
        }
    }

    /// Codex review of #23970: the glass's own theme tint is too light for the ink over a pure
    /// white or black backdrop, and a theme change while the tooltip showed left the labels in the
    /// old theme. In every theme, light and dark, plain, colored and low contrast, switched while
    /// the tooltip shows, the labels take the new ink and the text keeps 4.5:1 over the tint the
    /// panel draws, laid on pure black and pure white.
    @Test func theTextReadsInEveryThemeAndFollowsAThemeChangeWhileShown() async throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let clock = ManualClock()
        let (window, buttons, presenter, scope) = try Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.closeAfterTest()
        }
        try await Self.rest(on: buttons[0], presenter, clock)
        let panel = presenter.panel
        #expect(panel.isVisible)
        for (index, input) in Self.themes.enumerated() {
            scope.setOverride(try #require(ThemeSpec("Tooltip Theme \(index)")), input: input, animated: false)
            let name = "\(input.background)"
            #expect(presenter.shown?.text == "Back", "\(name): the theme change put the tooltip away")
            let ink = try Self.ink(of: panel)
            let surface = TooltipSurface(scope.tokens, lift: ChromeTunables.opaqueOverlayLift.value)
            #expect(abs(ink.red - surface.ink.red) < 0.01 && abs(ink.green - surface.ink.green) < 0.01
                && abs(ink.blue - surface.ink.blue) < 0.01, "\(name): the label kept the old ink")
            let hint = try Self.rgb(try #require(panel.content.keycap?.label.textColor, "the shortcut has no keycap"))
            let wantHint = try Self.rgb(scope.perform { Palette.textSecondary })
            #expect(abs(hint.red - wantHint.red) < 0.01 && abs(hint.green - wantHint.green) < 0.01
                && abs(hint.blue - wantHint.blue) < 0.01, "\(name): the shortcut hint kept the old ink")
            let tint = try Self.tint(of: panel)
            let expected = surface.tint
            #expect(abs(tint.alpha - expected.alpha) < 0.01 && abs(tint.red - expected.red) < 0.01, "\(name): the tint kept the old theme")
            #expect(tint.alpha < 1, "\(name): the tint is solid")
            let contrast = TooltipSurface.worstContrast(ink: ink, tint: tint)
            #expect(contrast >= ThemeTokens.minimumTextContrast, "\(name): the text reads \(contrast):1 over black or white")
        }
    }

    /// The legibility tint the panel draws, in sRGB.
    static func tint(of panel: TooltipPanel) throws -> ThemeRGB {
        try rgb(try #require(panel.legibility.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))))
    }

    /// The primary ink the panel draws, in sRGB.
    static func ink(of panel: TooltipPanel) throws -> ThemeRGB {
        try rgb(try #require(panel.text.textColor))
    }

    static func rgb(_ color: NSColor) throws -> ThemeRGB {
        let color = try #require(color.usingColorSpace(.sRGB))
        return ThemeRGB(red: Double(color.redComponent), green: Double(color.greenComponent),
                        blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
    }
}
