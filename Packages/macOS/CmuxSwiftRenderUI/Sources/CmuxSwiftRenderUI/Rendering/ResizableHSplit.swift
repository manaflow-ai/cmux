import AppKit
import CmuxSwiftRender

/// Native two-column split used by interpreted custom sidebars.
@MainActor
final class ResizableHSplit: NSSplitView, NSSplitViewDelegate {
    private let minimumColumnWidth: CGFloat = 80
    private var hasRestoredFraction = false

    init(
        columns: [RenderNode],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) {
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        autosaveName = "cmux.customSidebar.nativeSplit"
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false

        for node in Array(columns.prefix(2)) {
            let rendered = RenderNodeView(node: node, dispatch: dispatch, contentInsets: contentInsets)
            let padded = SidebarSplitColumnContent(contentView: rendered)
            let scroll = SidebarScrollContainer(documentView: padded, axis: .vertical)
            scroll.contentInsets = NSEdgeInsets(
                top: contentInsets.top, left: 0, bottom: contentInsets.bottom, right: 0
            )
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumColumnWidth).isActive =
                true
            addArrangedSubview(scroll)
        }
        while arrangedSubviews.count < 2 {
            addArrangedSubview(NSView())
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard !hasRestoredFraction, bounds.width > minimumColumnWidth * 2 else { return }
        hasRestoredFraction = true
        let fraction = min(
            0.9, max(0.1, UserDefaults.standard.double(forKey: "cmux.customSidebar.splitFraction"))
        )
        let resolved = fraction == 0 ? 0.5 : fraction
        setPosition(bounds.width * resolved, ofDividerAt: 0)
    }

    func splitView(
        _: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt _: Int
    ) -> CGFloat {
        min(
            max(minimumColumnWidth, proposedPosition),
            max(minimumColumnWidth, bounds.width - minimumColumnWidth)
        )
    }

    func splitViewDidResizeSubviews(_: Notification) {
        guard bounds.width > 0, let leading = arrangedSubviews.first else { return }
        UserDefaults.standard.set(
            Double(leading.frame.width / bounds.width), forKey: "cmux.customSidebar.splitFraction"
        )
    }
}

@MainActor
private final class SidebarSplitColumnContent: SidebarFlippedView {
    init(contentView: NSView) {
        super.init(frame: .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
