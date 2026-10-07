import AppKit
import CmuxNextDesign

// UPDATE-CARD: the staged update card sits directly above the footer (the
// spaces dots and the Settings band below them), under the R114 card
// stack. It is the sidebar's own view, not a band item, so minimal mode's
// band fade never hides the only update notice. Without a staged update it
// takes no room and the footer is the account and settings only.
extension SidebarView {
    func installUpdateCard() {
        let card = updateCardView
        // red: UPDATE-CARD not implemented
        addSubview(card)
    }

    /// The room the card takes above the footer: the card and a gap above
    /// and below it; 0 without a staged update.
    var updateCardSlotHeight: CGFloat {
        updateCardView.card == nil ? 0 : SidebarUpdateCardView.height + 2 * Metrics.space2
    }

    /// Lays the card out in its slot, which ends at `bottom`, inset like the
    /// card stack's cards.
    func placeUpdateCard(above bottom: CGFloat, slotHeight: CGFloat) {
        guard slotHeight > 0 else {
            updateCardView.frame = .zero
            return
        }
        let inset = Metrics.space3, height = SidebarUpdateCardView.height
        updateCardView.frame = NSRect(x: inset, y: bottom - Metrics.space2 - height,
                                      width: max(0, bounds.width - 2 * inset), height: height).integral
    }
}
