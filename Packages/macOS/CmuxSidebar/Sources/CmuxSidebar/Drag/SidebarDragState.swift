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
    /// Source identity retained after presentation dismissal for an explicit
    /// finish command. Generic `clearDrag()` deliberately does not consult
    /// this value; only the token-scoped finish path may use it.
    private var dismissedSessionId: UUID?

    /// Pin state of a foreign (cross-window) dragged workspace, resolved once
    /// when the drag is mirrored into this window and reused for every hover
    /// update. A workspace's pin state can't change mid-drag, so this avoids a
    /// cross-window scan on each pointer-move. `nil` when no foreign drag is
    /// mirrored here.
    public var foreignDraggedIsPinned: Bool?

    private let workspaceDragRegistry: any SidebarWorkspaceDragRegistering

    private var sessionRegistry: (any SidebarWorkspaceDragSessionRegistering)? {
        workspaceDragRegistry as? any SidebarWorkspaceDragSessionRegistering
    }

    /// Creates a drag state wired to the process-wide cross-window registry.
    /// - Parameter workspaceDragRegistry: The shared registry that records which
    ///   workspace is being dragged across all windows.
    public init(workspaceDragRegistry: any SidebarWorkspaceDragRegistering) {
        self.workspaceDragRegistry = workspaceDragRegistry
        sessionRegistry?.register(self)
    }

    deinit {}

    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// used by the drop path to resolve a drag that originated in another window.
    public var currentWorkspaceDragId: UUID? {
        workspaceDragRegistry.currentWorkspaceId
    }

    /// The token of the process-wide drag currently in flight, if any.
    public var currentWorkspaceDragSessionId: UUID? {
        sessionRegistry?.currentSessionId ?? workspaceDragRegistry.currentWorkspaceId
    }

    /// The most recently issued session token, including completed sessions.
    /// A deferred drop uses this generation fence to reject work after a newer
    /// drag has already started and ended.
    public var mostRecentWorkspaceDragSessionId: UUID? {
        sessionRegistry?.mostRecentSessionId
    }

    /// The workspace paired with the most recently issued drag session.
    public var mostRecentWorkspaceDragWorkspaceId: UUID? {
        sessionRegistry?.mostRecentWorkspaceId
    }

    /// Returns whether a deferred operation belongs to the current session or
    /// to the most recently completed session. The latter is necessary because
    /// AppKit can deliver target updates after its native source completion;
    /// the registry's generation history still fences that operation from any
    /// newer drag.
    public func acceptsWorkspaceDragSession(
        sessionId: UUID,
        workspaceId: UUID
    ) -> Bool {
        if let currentSessionId = currentWorkspaceDragSessionId {
            return currentSessionId == sessionId
                && currentWorkspaceDragId == workspaceId
        }
        return mostRecentWorkspaceDragSessionId == sessionId
            && mostRecentWorkspaceDragWorkspaceId == workspaceId
    }

    /// A sidebar payload is live only when its token matches the process-wide
    /// native session. A residual or legacy value cannot create a session.
    public func acceptsLiveSidebarSessionForCurrentPasteboard(
        pasteboardProvider: @escaping @MainActor () -> NSPasteboard = {
            NSPasteboard(name: .drag)
        }
    ) -> Bool {
        guard let currentSessionId = currentWorkspaceDragSessionId else { return false }
        let pasteboard = pasteboardProvider()
        let type = NSPasteboard.PasteboardType(
            SidebarWorkspaceDragSession.pasteboardTypeIdentifier
        )
        let raw = pasteboard.string(forType: type)
            ?? pasteboard.data(forType: type).flatMap { String(data: $0, encoding: .utf8) }
        return SidebarWorkspaceDragPayloadParser().sessionId(from: raw) == currentSessionId
    }

    /// Marks `tabId` as this window's dragged workspace and records it as the
    /// process-wide in-flight drag.
    @discardableResult
    public func beginDragging(tabId: UUID) -> SidebarWorkspaceDragSession {
        let session: SidebarWorkspaceDragSession
        if let sessionRegistry {
            session = sessionRegistry.beginSession(workspaceId: tabId)
        } else {
            workspaceDragRegistry.begin(workspaceId: tabId)
            session = SidebarWorkspaceDragSession(id: tabId, workspaceId: tabId)
        }
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
        guard let sessionRegistry else { return false }
        let session = sessionRegistry.beginNativeSession(workspaceId: tabId)
        activate(session: session, role: .source(session.id))
        guard sessionRegistry.beginNativeDragging(
            sessionId: session.id,
            pasteboardItem: pasteboardItem,
            sourceView: sourceView,
            event: event,
            draggingFrame: draggingFrame,
            dragImage: dragImage,
            capabilityValue: session.pasteboardValue
        ) else {
            sessionRegistry.nativeDraggingSessionDidEnd(
                sessionId: session.id,
                capabilityValue: session.pasteboardValue
            )
            clearPresentation()
            return false
        }
        return true
    }

    /// Reclaims superseded native source holds after a real pointer boundary.
    ///
    /// This is intentionally separate from ``finishDrag()``: ordinary
    /// presentation teardown may clear logical state while AppKit still owns a
    /// live source, whereas a new pointer boundary proves that older native
    /// sessions are no longer in their event loop.
    public func reclaimSupersededNativeSources(excludingSessionId: UUID) {
        sessionRegistry?.reclaimSupersededNativeSources(
            excludingSessionId: excludingSessionId
        )
    }

    /// Mirrors the coordinator's current session into a destination window.
    @discardableResult
    public func mirrorDragging(tabId: UUID) -> Bool {
        let session: SidebarWorkspaceDragSession?
        if let sessionRegistry {
            session = sessionRegistry.session(matching: tabId)
        } else if workspaceDragRegistry.currentWorkspaceId == tabId {
            session = SidebarWorkspaceDragSession(id: tabId, workspaceId: tabId)
        } else {
            session = nil
        }
        guard let session else { return false }
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
            if let sessionRegistry {
                sessionRegistry.end(sessionId: sessionId)
            } else {
                workspaceDragRegistry.end(workspaceId: sessionId)
            }
        }
        clearPresentation()
    }

    /// Removes this view's transient presentation without ending the native
    /// process-wide session.
    public func dismissPresentation() {
        // Presentation teardown is not a source completion signal. Drop the
        // local role as well as the rendered id so a later generic clear from
        // this rebuilt view cannot end the still-live native session.
        dismissedSessionId = sessionRole?.sessionId ?? dismissedSessionId
        sessionRole = nil
        foreignDraggedIsPinned = nil
        draggedTabId = nil
        clearDropIndicator()
    }

    /// Completes a drag from either its source or destination presentation.
    public func finishDrag() {
        if let sessionId = sessionRole?.sessionId ?? dismissedSessionId {
            if let sessionRegistry {
                sessionRegistry.end(sessionId: sessionId)
            } else {
                workspaceDragRegistry.end(workspaceId: sessionId)
            }
        }
        clearPresentation()
    }

    /// Completes a specific native session and revokes its matching payload.
    public func finishDrag(sessionId: UUID, capabilityValue: String) {
        if let sessionRegistry {
            sessionRegistry.nativeDraggingSessionDidEnd(
                sessionId: sessionId,
                capabilityValue: capabilityValue
            )
        } else {
            workspaceDragRegistry.end(workspaceId: sessionId)
        }
        if self.sessionRole?.sessionId == sessionId || dismissedSessionId == sessionId {
            clearPresentation()
        }
    }

    func coordinatorDidEnd(sessionId: UUID) {
        guard self.sessionRole?.sessionId == sessionId || dismissedSessionId == sessionId else { return }
        clearPresentation()
    }

    private func activate(
        session: SidebarWorkspaceDragSession,
        role: SidebarWorkspaceDragSessionRole
    ) {
        dismissedSessionId = nil
        sessionRole = role
        draggedTabId = session.workspaceId
        clearDropIndicator()
    }

    private func clearPresentation() {
        sessionRole = nil
        dismissedSessionId = nil
        foreignDraggedIsPinned = nil
        draggedTabId = nil
        clearDropIndicator()
    }
}
