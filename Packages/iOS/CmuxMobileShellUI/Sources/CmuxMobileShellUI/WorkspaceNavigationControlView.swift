#if os(iOS)
import SwiftUI
import UIKit

/// Custom bar content follows UIKit's margins, including the glass padding.
/// Its natural width changes with the label instead of a per-control estimate.
@MainActor
final class WorkspaceNavigationControlView: UIView {
    private let contentView: UIView & UIContentView
    private var width: NSLayoutConstraint?
    private let minimumWidth: CGFloat

    init(content: AnyView, minimumWidth: CGFloat) {
        self.minimumWidth = minimumWidth
        contentView = UIHostingConfiguration { content }.margins(.all, 0).minSize(width: 0, height: 0).makeContentView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            contentView.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        let contentSize = contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: max(minimumWidth, contentSize.width + layoutMargins.left + layoutMargins.right), height: 36)
    }

    override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        refreshContentSize()
    }

    func update(content: AnyView) {
        contentView.configuration = UIHostingConfiguration { content }.margins(.all, 0).minSize(width: 0, height: 0)
        refreshContentSize()
    }

    private func refreshContentSize() {
        contentView.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        width?.constant = intrinsicContentSize.width
    }
}
#endif
