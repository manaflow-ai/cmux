#if os(iOS)
import SwiftUI
import UIKit

/// Custom bar content follows UIKit's margins, including the glass padding.
/// Its natural width changes with the label instead of a per-control estimate.
@MainActor
final class WorkspaceNavigationControlView: UIView {
    private let host: UIHostingController<AnyView>
    private var width: NSLayoutConstraint?

    init(host: UIHostingController<AnyView>) {
        self.host = host
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            host.view.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        width = widthAnchor.constraint(equalToConstant: intrinsicContentSize.width)
        width?.isActive = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let contentSize = host.sizeThatFits(in: UIView.layoutFittingExpandedSize)
        return CGSize(width: contentSize.width + layoutMargins.left + layoutMargins.right, height: 36)
    }

    override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        refreshContentSize()
    }

    func refreshContentSize() {
        host.view.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        width?.constant = intrinsicContentSize.width
    }
}
#endif
