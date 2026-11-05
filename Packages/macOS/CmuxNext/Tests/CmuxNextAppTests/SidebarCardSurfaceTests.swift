import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Every sidebar card sits on one shared surface, `CardSurfaceView`: the veil of
/// ``FloatingGlassStyle/card`` for the card's appearance (user 2026-10-20, after Rex), over the
/// sidebar's own glass; the update and notice cards' veil takes the theme's glass tint (Leo
/// 2026-11-02 and 2026-11-03). Before 2026-10-20 that surface was the composer's 13% text fill
/// (Leo 2026-10-13, cx-5dvig). The Update Ready card once drew an opaque elevated fill that hid the
/// wallpaper, and the notice and tip cards drew Liquid Glass under a veil: three different cards.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarCardSurfaceTests {
    /// The backmost fill that covers the whole card. Each covering layer draws first (it would on
    /// the next display pass), in the card's theme.
    static func fill(of card: NSView) -> NSColor? {
        func walk(_ view: NSView) -> NSColor? {
            guard !view.isHidden else { return nil }
            let covers = view.bounds.width >= card.bounds.width - 1 && view.bounds.height >= card.bounds.height - 1
            // cmux's own views only: AppKit's assert their layer state when drawn out of a pass.
            let ours = Bundle(for: type(of: view)) != Bundle(for: NSView.self)
            if covers, ours, view.layer != nil, view.wantsUpdateLayer { view.updateLayer() }
            if covers, let color = view.layer?.backgroundColor, color.alpha > 0 {
                return NSColor(cgColor: color)
            }
            return view.subviews.lazy.compactMap(walk).first
        }
        return walk(card)
    }

    /// Shows `card` in a window in the purple theme and returns its fill and the shared card veil.
    static func fills(_ card: NSView) throws -> (card: NSColor?, veil: NSColor) {
        let oldOverride = ReduceTransparency.shared.override
        // Surface assertions cover the translucent branch. Pin the shared source so a
        // Blacksmith accessibility preference cannot change the branch under test.
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = oldOverride }
        _ = NSApplication.shared
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = card
        scope.root(card)
        window.orderFrontRegardless()
        card.layoutSubtreeIfNeeded()
        let veil = CardSurfaceView.style.look(isDark: card.themeTokens.isDark).veil.nsColor
        return (fill(of: card), veil)
    }

    /// `card` draws the card veil's opacity in the theme's glass tint (the purple theme's
    /// background), not the neutral gray.
    static func expectThemedCardSurface(_ card: NSView, _ name: String) throws {
        let (fill, veil) = try fills(card)
        let drawn = try #require(fill?.usingColorSpace(.sRGB), "the \(name) card draws no fill")
        let gray = try #require(veil.usingColorSpace(.sRGB))
        let tint = try #require(ThemedOverlayColorsTests.purpleRoom().perform { Palette.glassTint }.usingColorSpace(.sRGB))
        #expect(abs(drawn.alphaComponent - gray.alphaComponent) < 0.01,
                "the \(name) card's fill is \(drawn.alphaComponent) opaque, not the card veil's \(gray.alphaComponent)")
        #expect(abs(drawn.redComponent - tint.redComponent) < 0.01 && abs(drawn.greenComponent - tint.greenComponent) < 0.01
                && abs(drawn.blueComponent - tint.blueComponent) < 0.01,
                "the \(name) card's fill \(drawn) is not the theme's glass tint \(tint)")
        #expect(drawn.blueComponent - drawn.greenComponent > 0.1, "the \(name) card's fill \(drawn) has no purple cast")
    }

    @Test func theUpdateReadyCardSitsOnTheSharedCardSurfaceInTheThemesTint() throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let card = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 120))
        card.configure(SidebarUpdateCard(title: "Update Ready", detail: "nightly 3845050 · Oct 13", buttonTitle: "Restart to Update",
                                         automaticUpdatesTitle: "Automatic Updates", automaticUpdates: true,
                                         notes: .init(headline: "Update Ready", keepsRunning: "")))
        try Self.expectThemedCardSurface(card, "Update Ready")
    }

    @Test func aNoticeOrTipCardSitsOnTheSharedCardSurfaceInTheThemesTint() throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 80),
                                         reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()))
        card.configure(SidebarNoticeCard(id: "tip", eyebrow: "Tip", title: "Drag a tab to split the pane"))
        try Self.expectThemedCardSurface(card, "notice")
    }

    /// Leo 2026-11-02, on the Updated card as a gray card over his themed sidebar: "why is the
    /// update thing unthemed". The Updated card's veil is the theme's glass tint (the purple
    /// theme's background) at the card veil's opacity, not the neutral gray.
    @Test func theUpdatedCardTakesTheThemesTint() throws {
        let host = SidebarUpdatedCardHost(frame: NSRect(x: 0, y: 0, width: 216, height: 80))
        #expect(host.surface.takesThemeTint, "the Updated card draws the neutral gray veil")
        host.surface.frame = host.bounds
        try Self.expectThemedCardSurface(host.surface, "Updated")
    }

    /// Leo 2026-11-03, on the Downloading Update card: "will this be themeed properly?". The
    /// download's bar is the theme's accent (`Palette.accentFill`) in a dark and a light theme, with
    /// and without a chosen accent, never the fixed secondary-text gray it was.
    @Test(arguments: [BarTheme(background: 0x2B1650, foreground: 0xF4E3FF, accent: .neutral),
                      BarTheme(background: 0x2B1650, foreground: 0xF4E3FF, accent: .magenta),
                      BarTheme(background: 0xF7F2FF, foreground: 0x2B1650, accent: .neutral),
                      BarTheme(background: 0xF7F2FF, foreground: 0x2B1650, accent: .magenta)])
    func theDownloadBarIsTheThemesAccent(_ theme: BarTheme) throws {
        _ = NSApplication.shared
        let scope = ThemeScope(level: .room)
        var input = ThemeInput(background: ThemeRGB(hex: theme.background), foreground: ThemeRGB(hex: theme.foreground))
        input.accent = theme.accent
        scope.setOverride(try #require(ThemeSpec("Stress Purple")), input: input, animated: false)
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 96),
                                         reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()))
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = card
        scope.root(card)
        card.configure(SidebarNoticeCard(id: "update", title: "Downloading Update", detail: "57.3 MB of 257.1 MB · 22%",
                                         progress: .fraction(0.22)))
        card.layoutSubtreeIfNeeded()
        let (accentFill, gray) = scope.perform { (Palette.accentFill.cgColor, Palette.textSecondary.cgColor) }
        let bar = try #require(card.bar.backgroundColor, "the download bar has no color")
        #expect(bar == accentFill, "the download bar is \(bar), not the theme's accent \(accentFill)")
        #expect(bar != gray, "the download bar is the fixed secondary-text gray")
        #expect(card.track.backgroundColor == scope.perform { Palette.hoverFill.cgColor }, "the bar's track is not the theme's hover fill")
    }

    /// A dark or light theme, with or without a chosen accent.
    struct BarTheme: Sendable {
        var background: UInt32
        var foreground: UInt32
        var accent: ThemeAccent
    }
}
