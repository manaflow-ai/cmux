#if os(iOS)
import SwiftUI
import UIKit

/// Hosts one SwiftUI toolbar control in a native UIBarButtonItem.
/// UINavigationBar owns placement; this view only supplies the standard
/// 36-point bar-item hit area. UIKit supplies the bar-item margins.
@MainActor
final class WorkspaceNavigationControlView: UIView {
    private let contentView: UIView & UIContentView
    private var contentWidth: NSLayoutConstraint!
    private var itemWidth: NSLayoutConstraint!

    static func width(for id: WorkspaceNavigationBar.Item.ID) -> CGFloat {
        switch id {
        case .back, .sidebar:
            52
        case .changes:
            55
        case .terminals, .overflow:
            42
        case .alternateScreen:
            41
        }
    }

    init(content: AnyView, width: CGFloat) {
        contentView = UIHostingConfiguration { content.ignoresSafeArea() }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
            .makeContentView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.preservesSuperviewLayoutMargins = false
        contentView.insetsLayoutMarginsFromSafeArea = false
        contentView.layoutMargins = .zero
        addSubview(contentView)
        contentWidth = contentView.widthAnchor.constraint(equalToConstant: width)
        itemWidth = widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentWidth,
            itemWidth,
            heightAnchor.constraint(equalToConstant: 36),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let size = contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: size.width, height: 36)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    func update(content: AnyView) {
        contentView.configuration = UIHostingConfiguration { content.ignoresSafeArea() }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
        contentView.invalidateIntrinsicContentSize()
        // The bar item width is part of the native toolbar contract. The
        // hosted SwiftUI control may change its label, but it must not change
        // the UIKit item geometry and push the title into the action group.
        contentWidth.constant = itemWidth.constant
        invalidateIntrinsicContentSize()
    }
}
#endif
