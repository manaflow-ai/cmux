import AppKit

/// One shown dialog's region (the window, the tab, or the app panel's room), with its ``CmuxDialogView`` card
/// in the middle. Each layout reports the card's rect to the presentation (``CmuxDialogPresentation/cardRect``),
/// so the host grows a region that is too small for the card and takes clicks only on the card in a tab.
@MainActor
final class CmuxDialogRegionView: NSView {
    let card: CmuxDialogView

    init(card: CmuxDialogView) {
        self.card = card
        super.init(frame: .zero)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override func layout() {
        super.layout()
        let rect = card.frame
        guard rect.width > 0, rect.height > 0, card.dialog.cardRect != rect else { return }
        card.dialog.cardRect = rect
    }
}
