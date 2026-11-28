public import AppKit
import CmuxNextDesign

/// Where the suggestion card is, as automation reads it (`debug.omnibar`):
/// on which overlay host layer, its frame and the bar's in window
/// coordinates, and each row's kind.
public struct OmnibarDebugCard: Sendable, Equatable {
    /// The card is a `.pane` overlay of the window's overlay host.
    public var paneLayer: Bool
    public var cardInWindow: NSRect
    public var barInWindow: NSRect
    public var rowKinds: [String]

    /// Flush under the bar and as wide as the card top.
    public var isFlushUnderBar: Bool {
        cardInWindow.maxY == barInWindow.minY && cardInWindow.minX == barInWindow.minX - OmnibarStyle.cardSideOutset
            && cardInWindow.width == barInWindow.width + 2 * OmnibarStyle.cardSideOutset
    }
}

extension AddressBarView {
    /// The shown card, or nil when it is closed.
    public var debugCard: OmnibarDebugCard? {
        guard let handle = panel.overlay, !handle.isDismissed, let window,
              let host = WindowOverlayHost.existingHost(for: window) else { return nil }
        let card = panel.cardView
        return OmnibarDebugCard(
            paneLayer: host.presentedHandles.contains { $0 === handle } && host.layerIndex(of: handle) == 0,
            cardInWindow: card.convert(card.bounds, to: nil), barInWindow: convert(bounds, to: nil),
            rowKinds: controller.state.popup.rows.map { String(describing: $0.kind) }
        )
    }

    /// Presses row `index` through its own click path (the row's
    /// accessibility press, which a pointer click also runs). False when
    /// the card has no such row.
    public func debugPressRow(_ index: Int) -> Bool {
        guard panel.rowViews.indices.contains(index) else { return false }
        return panel.rowViews[index].accessibilityPerformPress()
    }
}
