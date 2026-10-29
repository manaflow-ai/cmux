import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A corner badge sizes its ring to the glyph's kind: around the Codex-like set's 6 pt dot, the
/// dot; around any other mark, its 10 pt box. A switch of the icon set while a row shows the badge
/// keeps the glyph visible, so the glyph must still tell the badge to lay out, or the ring keeps
/// the old set's size until the row's states change.
@MainActor @Suite(.serialized) struct RowBadgeIconSetRingTests {
    private static func apply(_ set: StatusIconSet) {
        var config = StatusIndicatorConfig.current
        config.iconSet = set
        config.reduceMotion = false
        config.settings.animation = .animated
        StatusIndicatorAppearance.shared.apply(config)
    }

    @Test func anIconSetSwitchResizesTheCornerRing() {
        defer { StatusIndicatorAppearance.shared.apply(StatusIndicatorConfig.current) }
        Self.apply(.current)
        let view = RowBadgeView(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
        view.configure([.success], look: .corner)
        view.layoutSubtreeIfNeeded()
        let ring = view.backdrops(at: 0)[0]
        let side = RowBadgeView.glyphSide + 2 * RowBadgeView.ringWidth
        let dot = RowBadgeView.dotSide + 2 * RowBadgeView.ringWidth
        #expect(ring.frame.width == side, "a check: the ring around the glyph's box")

        Self.apply(.codex)
        view.layoutSubtreeIfNeeded()
        #expect(ring.frame.width == dot, "the Codex-like dot: the ring hugs the dot")

        Self.apply(.current)
        view.layoutSubtreeIfNeeded()
        #expect(ring.frame.width == side, "back to the check: the ring around its box again")
    }
}
