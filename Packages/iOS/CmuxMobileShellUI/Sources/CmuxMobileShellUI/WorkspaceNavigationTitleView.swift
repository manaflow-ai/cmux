#if os(iOS)
import SwiftUI
import UIKit

/// UINavigationBar proposes the space remaining between its button groups.
/// This view accepts that width, then gives the same bounds to the title menu.
/// There is deliberately no minimum title width or screen/size-class estimate.
@MainActor
final class WorkspaceNavigationTitleView: UIView {
    private let host: UIHostingController<AnyView>
    private let capsule: UIVisualEffectView

    init(host: UIHostingController<AnyView>) {
        self.host = host
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            capsule = UIVisualEffectView(effect: glass)
            capsule.cornerConfiguration = .capsule()
        } else {
            capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            capsule.clipsToBounds = true
        }
        super.init(frame: .zero)
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
        let content = host.sizeThatFits(in: UIView.layoutFittingExpandedSize)
        return CGSize(width: content.width + 20, height: 44)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let ideal = intrinsicContentSize
        return CGSize(width: min(ideal.width, max(0, size.width)), height: min(ideal.height, size.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        if #unavailable(iOS 26.0) {
            capsule.layer.cornerRadius = bounds.height / 2
        }
        let inset = min(10, bounds.width / 2)
        host.view.frame = bounds.insetBy(dx: inset, dy: 0)
    }
}
#endif
