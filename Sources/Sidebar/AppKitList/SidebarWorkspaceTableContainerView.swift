import AppKit

/// AppKit container stacking drag destinations above the virtualized table.
@MainActor
final class SidebarWorkspaceTableContainerView: NSView {
    let scrollView = NSScrollView()
    let clipView = SidebarWorkspaceTableClipView()
    let tableView = SidebarWorkspaceTableViewImpl()
    let reorderDropView = SidebarWorkspaceReorderDropView()
    let bonsplitDropView = SidebarBonsplitTabWorkspaceDropView()
    let emptyDropIndicatorView = SidebarWorkspaceTableEmptyDropIndicatorView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        scrollView.contentView = clipView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        reorderDropView.translatesAutoresizingMaskIntoConstraints = false
        bonsplitDropView.translatesAutoresizingMaskIntoConstraints = false
        emptyDropIndicatorView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(scrollView)
        addSubview(reorderDropView)
        addSubview(bonsplitDropView)
        addSubview(emptyDropIndicatorView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            reorderDropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            reorderDropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            reorderDropView.topAnchor.constraint(equalTo: topAnchor),
            reorderDropView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bonsplitDropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bonsplitDropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bonsplitDropView.topAnchor.constraint(equalTo: topAnchor),
            bonsplitDropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
