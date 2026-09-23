#if os(iOS)
import SwiftUI
import UIKit

/// UINavigationBar assigns the title's frame between its button groups.
/// This view gives its hosted menu the same bounds, allowing text to truncate.
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
        // Match the compact base toolbar's 151 point title island while
        // leaving UINavigationBar free to compress it when the trailing
        // cluster needs more room.
        return CGSize(width: max(0, content.width - 1), height: 44)
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
        let inset = min(3, bounds.width / 2)
        host.view.frame = bounds.insetBy(dx: inset, dy: 0)
    }
}
#endif
