import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Every sidebar card sits on the composer's surface (Leo 2026-10-13, cx-5dvig): the theme's text
/// at 13% over whatever is behind (the wallpaper on a wallpaper theme), as the agent composer's
/// `--acpmux-composer-bg`. The Update Ready card drew an opaque elevated fill that hid the
/// wallpaper, and the notice and tip cards drew Liquid Glass under a veil: three different cards.
@MainActor @Suite struct SidebarCardSurfaceTests {
    static func hasTransparency() -> Bool { !ReduceTransparency.shared.isEnabled }

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

    /// Shows `card` in a window in the purple theme and returns its fill and the composer's.
    static func fills(_ card: NSView) throws -> (card: NSColor?, composer: NSColor) {
        try #require(!ReduceTransparency.shared.isEnabled, "Reduce Transparency is on: every surface draws opaque")
        _ = NSApplication.shared
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = card
        scope.root(card)
        window.orderFrontRegardless()
        card.layoutSubtreeIfNeeded()
        let composer = scope.perform { Palette.textPrimary.withAlphaComponent(0.13) }
        return (fill(of: card), composer)
    }

    static func expectComposerSurface(_ card: NSView, _ name: String) throws {
        let (fill, composer) = try fills(card)
        let drawn = try #require(fill?.usingColorSpace(.sRGB), "the \(name) card draws no fill")
        let expected = try #require(composer.usingColorSpace(.sRGB))
        #expect(abs(drawn.alphaComponent - expected.alphaComponent) < 0.01,
                "the \(name) card's fill is \(drawn.alphaComponent) opaque, not the composer's \(expected.alphaComponent)")
        #expect(abs(drawn.redComponent - expected.redComponent) < 0.01 && abs(drawn.greenComponent - expected.greenComponent) < 0.01
                && abs(drawn.blueComponent - expected.blueComponent) < 0.01,
                "the \(name) card's fill \(drawn) is not the theme's text \(expected)")
    }

    @Test(.enabled("Reduce Transparency must be off for translucent card inspection") { await Self.hasTransparency() })
    func theUpdateReadyCardSitsOnTheComposersSurface() throws {
        let card = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 120))
        card.configure(SidebarUpdateCard(title: "Update Ready", detail: "nightly 3845050 · Oct 13", buttonTitle: "Restart to Update",
                                         automaticUpdatesTitle: "Automatic Updates", automaticUpdates: true,
                                         notes: .init(headline: "Update Ready", keepsRunning: "")))
        try Self.expectComposerSurface(card, "Update Ready")
    }

    @Test(.enabled("Reduce Transparency must be off for translucent card inspection") { await Self.hasTransparency() })
    func aNoticeOrTipCardSitsOnTheComposersSurface() throws {
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 80),
                                         reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()))
        card.configure(SidebarNoticeCard(id: "tip", eyebrow: "Tip", title: "Drag a tab to split the pane"))
        try Self.expectComposerSurface(card, "notice")
    }
}
