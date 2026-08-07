public import AppKit
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

    /// Explicit source/mirror role for the coordinator session represented by
    /// this window. The session token prevents an old clear from ending a newer
    /// drag of the same workspace.
    private var sessionRole: SidebarWorkspaceDragSessionRole?

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
        let session = workspaceDragRegistry.begin(workspaceId: tabId)
        activate(session: session, role: .source(session.id))
    }

    /// Begins an AppKit-owned workspace drag and binds local presentation to it.
    ///
    /// The registry retains the native source independently of the SwiftUI row,
    /// so row, sidebar, and window teardown cannot lose the terminal source
    /// callback.
    ///
    /// - Parameters:
    ///   - tabId: The workspace represented by the drag payload.
    ///   - pasteboardItem: The process-local workspace transfer payload.
    ///   - sourceView: The AppKit view whose window owns the drag session.
    ///   - event: The mouse-down event that initiated drag tracking.
    ///   - draggingFrame: The source-row frame in `sourceView` coordinates.
    ///   - dragImage: A snapshot displayed beneath the drag pointer.
    /// - Returns: `true` when the matching native session was started.
    @discardableResult
    public func beginNativeDragging(
        tabId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage
    ) -> Bool {
        let session = workspaceDragRegistry.begin(workspaceId: tabId)
        activate(session: session, role: .source(session.id))
        guard workspaceDragRegistry.beginNativeDragging(
            sessionId: session.id,
            pasteboardItem: pasteboardItem,
            sourceView: sourceView,
            event: event,
            draggingFrame: draggingFrame,
            dragImage: dragImage
        ) else {
            workspaceDragRegistry.end(sessionId: session.id)
            return false
        }
        return true
    }

    /// Mirrors the coordinator's current session into a destination window.
    /// Returns false when `tabId` is stale or no process-wide drag is active.
    @discardableResult
    public func mirrorDragging(tabId: UUID) -> Bool {
        guard let session = workspaceDragRegistry.currentSession,
              session.workspaceId == tabId else { return false }
        // Re-observing the same session must not downgrade its source to a
        // mirror; source ownership is immutable for the session's lifetime.
        if let sessionRole, sessionRole.sessionId == session.id {
            activate(session: session, role: sessionRole)
            return true
        }
        activate(session: session, role: .mirror(session.id))
        return true
    }

    /// Restores local presentation for an existing process-wide drag.
    ///
    /// Only a native source entrypoint may create a session. A destination or
    /// rebuilt view must never resurrect one from residual pasteboard data.
    @discardableResult
    public func activateDragging(tabId: UUID) -> Bool {
        mirrorDragging(tabId: tabId)
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

    /// Removes this view's transient drag presentation without ending the
    /// process-wide session.
    ///
    /// View teardown is not evidence that an AppKit drag ended: a source can
    /// remain live while its sidebar or window is being rebuilt. The retained
    /// native source will end the coordinator from AppKit's terminal callback.
    public func dismissPresentation() {
        foreignDraggedIsPinned = nil
        draggedTabId = nil
        clearDropIndicator()
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

    private func activate(
        session: SidebarWorkspaceDragSession,
        role: SidebarWorkspaceDragSessionRole
    ) {
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
