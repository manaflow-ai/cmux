#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

/// Extends the native soft edge through a host's floating avatar and name.
/// Only the material fades: rows remain intact below it, including reply copies.
final class ConversationHeaderMaterial: UIVisualEffectView {
    private let fadeView = HeaderMaterialMask()
    private var maskBounds = CGRect.null
    var fade: CAGradientLayer { fadeView.layer as! CAGradientLayer }

    init() {
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != maskBounds else { return }
        maskBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeView.frame = bounds
        // Stay fully blurred through the name, then clear gradually over the
        // same extent as the package's existing scroll-edge fade.
        let headerEnd = max(0, bounds.height - ConversationTopEdgeGeometry.extent)
        fade.locations = [0, NSNumber(value: Double(headerEnd / max(1, bounds.height))), 1]
        // UIKit copies a visual-effect mask into its internal effect views.
        // Reassign after geometry changes so rotation uses the new ramp too.
        mask = nil
        mask = fadeView
        CATransaction.commit()
    }
}

private final class HeaderMaterialMask: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
}
#endif
