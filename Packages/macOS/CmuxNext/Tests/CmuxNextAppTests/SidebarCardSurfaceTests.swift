import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Every sidebar card sits on one shared surface, `CardSurfaceView`: the neutral gray veil of
/// ``FloatingGlassStyle/card`` for the card's appearance (user 2026-10-20, after Rex), over the
/// sidebar's own glass. Before 2026-10-20 that surface was the composer's 13% text fill
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

    static func expectCardSurface(_ card: NSView, _ name: String) throws {
        let (fill, veil) = try fills(card)
        let drawn = try #require(fill?.usingColorSpace(.sRGB), "the \(name) card draws no fill")
        let expected = try #require(veil.usingColorSpace(.sRGB))
        #expect(abs(drawn.alphaComponent - expected.alphaComponent) < 0.01,
                "the \(name) card's fill is \(drawn.alphaComponent) opaque, not the card veil's \(expected.alphaComponent)")
        #expect(abs(drawn.redComponent - expected.redComponent) < 0.01 && abs(drawn.greenComponent - expected.greenComponent) < 0.01
                && abs(drawn.blueComponent - expected.blueComponent) < 0.01,
                "the \(name) card's fill \(drawn) is not the shared card veil \(expected)")
    }

    @Test func theUpdateReadyCardSitsOnTheSharedCardSurface() throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let card = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 120))
        card.configure(SidebarUpdateCard(title: "Update Ready", detail: "nightly 3845050 · Oct 13", buttonTitle: "Restart to Update",
                                         automaticUpdatesTitle: "Automatic Updates", automaticUpdates: true,
                                         notes: .init(headline: "Update Ready", keepsRunning: "")))
        try Self.expectCardSurface(card, "Update Ready")
    }

    @Test func aNoticeOrTipCardSitsOnTheSharedCardSurface() throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 80),
                                         reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()))
        card.configure(SidebarNoticeCard(id: "tip", eyebrow: "Tip", title: "Drag a tab to split the pane"))
        try Self.expectCardSurface(card, "notice")
    }
}
