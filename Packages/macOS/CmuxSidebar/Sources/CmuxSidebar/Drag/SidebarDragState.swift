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

    private let workspaceDragRegistry: any SidebarWorkspaceDragRegistering

    /// Creates a drag state wired to the process-wide cross-window registry.
    /// - Parameter workspaceDragRegistry: The shared registry that records which
    ///   workspace is being dragged across all windows.
    public init(workspaceDragRegistry: any SidebarWorkspaceDragRegistering) {
        self.workspaceDragRegistry = workspaceDragRegistry
        workspaceDragRegistry.register(self)
    }

    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// used by the drop path to resolve a drag that originated in another window.
    public var currentWorkspaceDragId: UUID? {
        workspaceDragRegistry.currentWorkspaceId
    }

    /// The token of the process-wide drag currently in flight, if any.
    public var currentWorkspaceDragSessionId: UUID? {
        workspaceDragRegistry.currentSessionId
    }

    /// Marks `tabId` as this window's dragged workspace and records it as the
    /// process-wide in-flight drag.
    @discardableResult
    public func beginDragging(tabId: UUID) -> SidebarWorkspaceDragSession {
        let session = workspaceDragRegistry.beginSession(workspaceId: tabId)
        activate(session: session, role: .source(session.id))
        return session
    }

    /// Begins an AppKit-owned workspace drag and binds local presentation to it.
    @discardableResult
    public func beginNativeDragging(
        tabId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage
    ) -> Bool {
        let session = workspaceDragRegistry.beginSession(workspaceId: tabId)
        activate(session: session, role: .source(session.id))
        guard workspaceDragRegistry.beginNativeDragging(
            sessionId: session.id,
            pasteboardItem: pasteboardItem,
            sourceView: sourceView,
            event: event,
            draggingFrame: draggingFrame,
            dragImage: dragImage,
            capabilityValue: session.pasteboardValue
        ) else {
            workspaceDragRegistry.end(sessionId: session.id)
            clearPresentation()
            return false
        }
        return true
    }

    /// Mirrors the coordinator's current session into a destination window.
    @discardableResult
    public func mirrorDragging(tabId: UUID) -> Bool {
        guard let session = workspaceDragRegistry.session(matching: tabId) else {
            return false
        }
        // Re-observing the same session must not downgrade its source role.
        if let sessionRole, sessionRole.sessionId == session.id {
            activate(session: session, role: sessionRole)
            return true
        }
        activate(session: session, role: .mirror(session.id))
        return true
    }

    /// Restores local presentation only when a native session is still live.
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

    /// Resets all drag state. Clears the process-wide registry entry only if this
    /// window originated the drag, so a destination window that merely mirrored a
    /// foreign id does not cancel the originating window's drag.
    public func clearDrag() {
        if case .source(let sessionId) = sessionRole {
            workspaceDragRegistry.end(sessionId: sessionId)
        }
        clearPresentation()
    }

    /// Removes this view's transient presentation without ending the native
    /// process-wide session.
    public func dismissPresentation() {
        foreignDraggedIsPinned = nil
        draggedTabId = nil
        clearDropIndicator()
    }

    /// Completes a drag from either its source or destination presentation.
    public func finishDrag() {
        if let sessionRole {
            workspaceDragRegistry.end(sessionId: sessionRole.sessionId)
        }
        clearPresentation()
    }

    /// Completes a specific native session and revokes its matching payload.
    public func finishDrag(sessionId: UUID, capabilityValue: String) {
        workspaceDragRegistry.nativeDraggingSessionDidEnd(
            sessionId: sessionId,
            capabilityValue: capabilityValue
        )
        if self.sessionRole?.sessionId == sessionId {
            clearPresentation()
        }
    }

    func coordinatorDidEnd(sessionId: UUID) {
        guard self.sessionRole?.sessionId == sessionId else { return }
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
