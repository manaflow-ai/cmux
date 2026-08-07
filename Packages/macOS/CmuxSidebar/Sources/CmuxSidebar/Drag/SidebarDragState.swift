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
/// Begin/clear of a drag also drive the process-wide cross-window coordinator so
/// a destination window can resolve a drag that originated elsewhere.
@MainActor
@Observable
public final class SidebarDragState {
    private enum SessionRole {
        case source(UUID)
        case mirror(UUID)

        var sessionId: UUID {
            switch self {
            case .source(let id), .mirror(let id): id
            }
        }
    }

    /// The workspace currently dragged in this window, or `nil` when no local
    /// drag is in flight. A destination window mirrors a foreign id here to drive
    /// the cross-window drop machinery.
    public private(set) var draggedTabId: UUID?

    /// Where the sidebar should currently render the drop indicator, or `nil`.
    public var dropIndicator: SidebarDropIndicator?

    /// Whether the active indicator is positioned against top-level (group-folded)
    /// rows rather than raw rows, so the overlay aligns to the same coordinate
    /// space the planner reasoned in.
    public var dropIndicatorUsesTopLevelRows = false

    /// The visible row scope where the active indicator should be drawn.
    public var dropIndicatorScope: SidebarWorkspaceReorderDropIndicatorScope = .raw

    /// True while the `debug.sidebar.simulate_drag` debug-only method is driving
    /// the drag state. The coordinator honors this by not starting its physical
    /// mouse lifecycle monitor, which would otherwise clear immediately because
    /// no real mouse is pressed during simulation. DEBUG-only by convention;
    /// never set in release flows.
    public var isSimulated: Bool = false

    /// Explicit source/mirror role for the coordinator session represented by
    /// this window. The session token prevents an old clear from ending a newer
    /// drag of the same workspace.
    private var sessionRole: SessionRole?

    /// Pin state of a foreign (cross-window) dragged workspace, resolved once
    /// when the drag is mirrored into this window and reused for every hover
    /// update. A workspace's pin state can't change mid-drag, so this avoids a
    /// cross-window scan on each pointer-move. `nil` when no foreign drag is
    /// mirrored here.
    public var foreignDraggedIsPinned: Bool?

    private let workspaceDragRegistry: SidebarWorkspaceDragRegistry

    /// Creates a drag state wired to the process-wide cross-window registry.
    /// - Parameter workspaceDragRegistry: The shared registry that records which
    ///   workspace is being dragged across all windows.
    public init(workspaceDragRegistry: SidebarWorkspaceDragRegistry) {
        self.workspaceDragRegistry = workspaceDragRegistry
        workspaceDragRegistry.register(self)
    }

    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// used by the drop path to resolve a drag that originated in another window.
    public var currentWorkspaceDragId: UUID? {
        workspaceDragRegistry.currentWorkspaceId
    }

    /// Marks `tabId` as this window's dragged workspace and records it as the
    /// process-wide in-flight drag.
    public func beginDragging(tabId: UUID) {
        let session = workspaceDragRegistry.begin(
            workspaceId: tabId,
            monitorLifecycle: !isSimulated
        )
        activate(session: session, role: .source(session.id))
    }

    /// Mirrors the coordinator's current session into a destination window.
    /// Returns false when `tabId` is stale or no process-wide drag is active.
    @discardableResult
    public func mirrorDragging(tabId: UUID) -> Bool {
        guard let session = workspaceDragRegistry.currentSession,
              session.workspaceId == tabId else { return false }
        // Re-observing the same session must not downgrade its source to a
        // mirror; source ownership is immutable for the session's lifetime.
        if sessionRole?.sessionId == session.id {
            return true
        }
        activate(session: session, role: .mirror(session.id))
        return true
    }

    /// Activates local presentation for `tabId`, mirroring an existing session
    /// when possible and otherwise taking ownership of a recovered live drag.
    public func activateDragging(tabId: UUID) {
        if !mirrorDragging(tabId: tabId) {
            beginDragging(tabId: tabId)
        }
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
        dropIndicatorScope = indicator == nil ? .raw : scope
        dropIndicatorUsesTopLevelRows = indicator != nil && scope == .topLevel
    }

    /// Clears any visible drop indicator.
    public func clearDropIndicator() {
        setDropIndicator(nil)
    }

    /// Resets local drag presentation. A source also ends its matching process-
    /// wide session; a mirror can disappear without cancelling the source.
    public func clearDrag() {
        if case .source(let sessionId) = sessionRole {
            workspaceDragRegistry.end(sessionId: sessionId)
        }
        clearPresentation()
    }

    /// Completes a drag from either its source or destination window.
    public func finishDrag() {
        if let sessionRole {
            workspaceDragRegistry.end(sessionId: sessionRole.sessionId)
        }
        clearPresentation()
    }

    func coordinatorDidEnd(sessionId: UUID) {
        guard sessionRole?.sessionId == sessionId else { return }
        clearPresentation()
    }

    private func activate(session: SidebarWorkspaceDragSession, role: SessionRole) {
        sessionRole = role
        draggedTabId = session.workspaceId
        clearDropIndicator()
    }

    private func clearPresentation() {
        sessionRole = nil
        foreignDraggedIsPinned = nil
        draggedTabId = nil
        clearDropIndicator()
    }
}
