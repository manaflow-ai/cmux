#if os(iOS)
import SwiftUI
import UIKit

/// UINavigationBar assigns the title's frame between its button groups.
/// This view insets its hosted menu by the base toolbar's glass padding.
/// There is deliberately no minimum title width or screen/size-class estimate.
@MainActor
final class WorkspaceNavigationTitleView: UIView {
    private let host: UIHostingController<AnyView>
    private let capsule: UIVisualEffectView
    private static let horizontalInset: CGFloat = 10
    private static let preferredContentWidth: CGFloat = 180

    init(host: UIHostingController<AnyView>) {
        self.host = host
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            capsule = UIVisualEffectView(effect: glass)
        } else {
            capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        }
        super.init(frame: .zero)
        if #available(iOS 26.0, *) {
            capsule.cornerConfiguration = .capsule()
        } else {
            capsule.clipsToBounds = true
        }
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(capsule)
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = true
        capsule.contentView.addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let content = host.view.intrinsicContentSize
        // Preserve the base title's preferred maximum. This is a presentation
        // preference, not an estimate of available space: the navigation bar
        // can reduce it further to fit its actual button groups.
        return CGSize(
            width: min(Self.preferredContentWidth, max(0, content.width)) + 2 * Self.horizontalInset,
            height: 44
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        if #unavailable(iOS 26.0) {
            capsule.layer.cornerRadius = bounds.height / 2
        }
        let inset = min(Self.horizontalInset, bounds.width / 2)
        host.view.frame = bounds.insetBy(dx: inset, dy: 0)
    }
}
#endif
