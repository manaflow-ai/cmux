import AppKit

/// AppKit container stacking the bonsplit drag destination above the
/// virtualized table. Workspace reorder drops land on the table itself
/// (native `validateDrop`/`acceptDrop`), so no reorder overlay is needed.
@MainActor
final class SidebarWorkspaceTableContainerView: NSView {
    let scrollView = NSScrollView()
    let clipView = SidebarWorkspaceTableClipView()
    let tableView = SidebarWorkspaceTableViewImpl()
    let bonsplitDropView = SidebarBonsplitTabWorkspaceDropView()
    let emptyDropIndicatorView = SidebarWorkspaceTableEmptyDropIndicatorView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // One layer-backed subtree keeps recycled hosted rows on AppKit's
        // accelerated scroll path without per-cell layer topology changes.
        wantsLayer = true
        scrollView.contentView = clipView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bonsplitDropView.translatesAutoresizingMaskIntoConstraints = false
        emptyDropIndicatorView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(scrollView)
        addSubview(bonsplitDropView)
        addSubview(emptyDropIndicatorView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
