public import Foundation
public import Observation
public import CmuxFoundation

/// Transient sidebar drag/drop state, owned by the sidebar view and passed by
/// reference into rows and drop delegates. `@Observable` gives per-property
/// tracking: writing `draggedTabId` or `dropIndicator` during a drag invalidates
/// only the views that read those properties (the dragged row's opacity and the
/// drop-indicator overlays), never the sidebar body or the `LazyVStack` itself.
/// That invariant is what prevents the layout-invalidation loop that caused
/// https://github.com/manaflow-ai/cmux/issues/2586.
///
/// Begin/clear of a drag also drive the process-wide cross-window identity
/// through the injected ``SidebarWorkspaceDragRegistering`` seam so a destination
/// window can resolve a drag that originated elsewhere.
@MainActor
@Observable
public final class SidebarDragState {
    /// The workspace currently dragged in this window, or `nil` when no local
    /// drag is in flight. A destination window mirrors a foreign id here to drive
    /// the cross-window drop machinery.
    public var draggedTabId: UUID?

    /// Where the sidebar should currently render the drop indicator, or `nil`.
    public var dropIndicator: SidebarDropIndicator?

    /// Whether the active indicator is positioned against top-level (group-folded)
    /// rows rather than raw rows, so the overlay aligns to the same coordinate
    /// space the planner reasoned in.
    public var dropIndicatorUsesTopLevelRows = false

    /// The visible row scope where the active indicator should be drawn.
    public var dropIndicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw

    /// True while the `debug.sidebar.simulate_drag` debug-only method is driving
    /// the drag state. Lifecycle observers honor this by not starting the
    /// failsafe monitor (which would otherwise post a `mouse_up_failsafe` clear
    /// immediately since no real mouse is pressed during simulation). DEBUG-only
    /// by convention; never set in release flows.
    public var isSimulated: Bool = false

    /// True only in the window that *originated* the current drag (set via
    /// ``beginDragging(tabId:)``). A destination window that mirrors a foreign
    /// drag id into ``draggedTabId`` for cross-window rendering does not own the
    /// process-wide registry entry, so it must not clear it when its own local
    /// drag state is reset.
    private var originatedActiveDrag = false

    /// Pin state of a foreign (cross-window) dragged workspace, resolved once
    /// when the drag is mirrored into this window and reused for every hover
    /// update. A workspace's pin state can't change mid-drag, so this avoids a
    /// cross-window scan on each pointer-move. `nil` when no foreign drag is
    /// mirrored here.
    public var foreignDraggedIsPinned: Bool?

    private let workspaceDragRegistry: any SidebarWorkspaceDragRegistering

    /// Creates a drag state wired to the process-wide cross-window registry.
    /// - Parameter workspaceDragRegistry: The shared registry that records which
    ///   workspace is being dragged across all windows.
    public init(workspaceDragRegistry: any SidebarWorkspaceDragRegistering) {
        self.workspaceDragRegistry = workspaceDragRegistry
    }

    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// used by the drop path to resolve a drag that originated in another window.
    public var currentWorkspaceDragId: UUID? {
        workspaceDragRegistry.currentWorkspaceId
    }

    /// Marks `tabId` as this window's dragged workspace and records it as the
    /// process-wide in-flight drag.
    public func beginDragging(tabId: UUID) {
        draggedTabId = tabId
        clearDropIndicator()
        originatedActiveDrag = true
        workspaceDragRegistry.begin(workspaceId: tabId)
    }

    /// Sets the current drop indicator and whether it is positioned in top-level
    /// row space.
    public func setDropIndicator(_ indicator: SidebarDropIndicator?, usesTopLevelRows: Bool = false) {
        setDropIndicator(indicator, scope: usesTopLevelRows ? .topLevel : .raw)
    }

    /// Sets the current drop indicator and the visible row scope it belongs to.
    public func setDropIndicator(
        _ indicator: SidebarDropIndicator?,
        scope: SidebarWorkspaceReorderDropIndicatorScope
    ) {
        dropIndicator = indicator
        dropIndicatorScope = scope
        dropIndicatorUsesTopLevelRows = indicator != nil && scope == .topLevel
    }

    /// Clears any visible drop indicator.
    public func clearDropIndicator() {
        setDropIndicator(nil)
    }

    /// Resets all drag state. Clears the process-wide registry entry only if this
    /// window originated the drag, so a destination window that merely mirrored a
    /// foreign id does not cancel the originating window's drag.
    public func clearDrag() {
        if originatedActiveDrag, let draggedTabId {
            workspaceDragRegistry.end(workspaceId: draggedTabId)
        }
        originatedActiveDrag = false
        foreignDraggedIsPinned = nil
        draggedTabId = nil
        clearDropIndicator()
    }
}
