import AppKit
import SwiftUI

/// Transparent AppKit anchor mounted as an overlay on each draggable sidebar
/// row, giving the drag coordinator an in-window `NSView` to begin a native
/// drag session from. `hitTest` returns nil (and the modifier also sets
/// `.allowsHitTesting(false)`), so clicks, context menus, and double-clicks
/// fall through to the SwiftUI row beneath.
@MainActor
struct SidebarTabDragAnchorView: NSViewRepresentable {
    let workspaceId: UUID
    let coordinator: SidebarTabDragSourceCoordinator

    func makeNSView(context: Context) -> SidebarTabDragAnchorNSView {
        let view = SidebarTabDragAnchorNSView()
        // Tell the coordinator when this anchor attaches to / detaches from a
        // window so it can cache the frame for the detached-drag fallback.
        view.onMoveToWindow = { [weak coordinator] window in
            coordinator?.anchorDidMove(toWindow: window, for: workspaceId)
        }
        // Dismantle deliberately carries no captured workspace id: SwiftUI can
        // replace and re-register a row's anchor before the old view's
        // dismantle runs, so the coordinator resolves the view's *current* id
        // through its reverse index instead of a stale closure capture.
        view.onDismantle = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.unregisterAnchor(view)
        }
        coordinator.registerAnchor(view, for: workspaceId)
        return view
    }

    func updateNSView(_ nsView: SidebarTabDragAnchorNSView, context: Context) {
        // Refresh the window-move callback: a LazyVStack can recycle the anchor
        // representable onto a different workspace, and the stale capture would
        // otherwise report window moves under the wrong id.
        nsView.onMoveToWindow = { [weak coordinator] window in
            coordinator?.anchorDidMove(toWindow: window, for: workspaceId)
        }
        coordinator.registerAnchor(nsView, for: workspaceId)
    }

    /// SwiftUI tears the anchor's row down (workspace closed, group collapsed)
    /// through here — and only here: a re-render that merely detaches the
    /// overlay from its window does NOT, so the detached-drag fallback keeps
    /// its cached frame. Unregisters the anchor so closed rows stop
    /// accumulating in the coordinator.
    static func dismantleNSView(_ nsView: SidebarTabDragAnchorNSView, coordinator: ()) {
        nsView.onMoveToWindow = nil
        nsView.onDismantle?()
        nsView.onDismantle = nil
    }
}

@MainActor
final class SidebarTabDragAnchorNSView: NSView {
    /// Informs the coordinator on every window attach/detach.
    var onMoveToWindow: ((NSWindow?) -> Void)?
    /// Informs the coordinator when SwiftUI dismantles the row's anchor.
    var onDismantle: (() -> Void)?

    /// Never captures the mouse: events fall through to the SwiftUI row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}
