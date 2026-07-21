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

    private var reorderOverlayLeading: NSLayoutConstraint?
    private var reorderOverlayTrailing: NSLayoutConstraint?
    private var reorderOverlayTop: NSLayoutConstraint?
    private var reorderOverlayBottom: NSLayoutConstraint?

    /// How far past the sidebar the reorder overlay reaches while a local
    /// drag is live, so a cursor drifting out of the narrow sidebar keeps
    /// the drag session (and its drop) instead of cancelling the preview.
    private static let expandedOverlaySlop = NSEdgeInsets(top: 60, left: 140, bottom: 100, right: 240)

    /// Grows/restores the reorder drop overlay around the sidebar. Drag
    /// destination routing is frame-based, so the expanded overlay keeps
    /// receiving dragging updates (and the drop) in the slop region; its
    /// hit-testing stays drag-only, so normal mouse events are unaffected.
    func setReorderOverlayExpanded(_ expanded: Bool) {
        let slop = expanded ? Self.expandedOverlaySlop : NSEdgeInsets()
        reorderOverlayLeading?.constant = -slop.left
        reorderOverlayTrailing?.constant = slop.right
        reorderOverlayTop?.constant = -slop.top
        reorderOverlayBottom?.constant = slop.bottom
        layoutSubtreeIfNeeded()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // One layer-backed subtree keeps recycled hosted rows on AppKit's
        // accelerated scroll path without per-cell layer topology changes.
        wantsLayer = true
        scrollView.contentView = clipView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        reorderDropView.translatesAutoresizingMaskIntoConstraints = false
        bonsplitDropView.translatesAutoresizingMaskIntoConstraints = false
        emptyDropIndicatorView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(scrollView)
        addSubview(reorderDropView)
        addSubview(bonsplitDropView)
        addSubview(emptyDropIndicatorView)
        let reorderLeading = reorderDropView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let reorderTrailing = reorderDropView.trailingAnchor.constraint(equalTo: trailingAnchor)
        let reorderTop = reorderDropView.topAnchor.constraint(equalTo: topAnchor)
        let reorderBottom = reorderDropView.bottomAnchor.constraint(equalTo: bottomAnchor)
        reorderOverlayLeading = reorderLeading
        reorderOverlayTrailing = reorderTrailing
        reorderOverlayTop = reorderTop
        reorderOverlayBottom = reorderBottom
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            reorderLeading,
            reorderTrailing,
            reorderTop,
            reorderBottom,
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
