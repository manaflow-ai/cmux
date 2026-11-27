import AppKit
import CmuxNextDesign

/// An app's sidebar section in AppKit: its scene (``AppSceneHostingView``, AppKit for the kit's list
/// pieces) in the frame of the `apps.section.look` prototype. `native` and `minimal` draw the scene
/// alone, so its rows line up with the built-in rows; `card` puts it on a subtle inset card (the hover
/// fill, the surface corner) with the card's vertical padding. The sidebar's section header row draws
/// the title and owns collapse, so no look draws a header here.
final class AppSectionView: NSView {
    let scene: AppSceneHostingView
    private let look: AppSectionLook
    private let card = CALayer()

    init(scene: AppSceneHostingView, look: AppSectionLook) {
        self.scene = scene
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        card.cornerCurve = .continuous
        card.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        card.isHidden = look != .card
        layer?.addSublayer(card)
        addSubview(scene)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    /// The card's horizontal inset and its vertical padding (0 for the looks without a card).
    private var cardInset: CGFloat { look == .card ? Metrics.space2 : 0 }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let content = scene.preferredHeight(width: max(0, width - 2 * cardInset))
        return content > 0 ? content + 2 * cardInset : 0
    }

    override func layout() {
        super.layout()
        let inset = cardInset
        let box = bounds.insetBy(dx: inset, dy: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = box
        card.cornerRadius = Metrics.surfaceCornerRadius
        CATransaction.commit()
        scene.frame = CGRect(x: box.minX, y: inset, width: box.width, height: max(0, box.height - 2 * inset))
    }

    override func updateLayer() {
        performWithTheme { card.backgroundColor = Palette.hoverFill.cgColor }
    }
}
