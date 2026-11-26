public import AppKit
public import Foundation

/// Process-wide coordinator for the workspace currently being dragged in any
/// window's sidebar.
///
/// The coordinator owns the session token, retained native drag source, and
/// weak set of source/mirror presentation states. AppKit's terminal source
/// callback clears the token and all matching window-local state together.
@MainActor
public final class SidebarWorkspaceDragRegistry: SidebarWorkspaceDragSessionRegistering {
    /// Provider used to inspect and clear the process drag pasteboard.
    public typealias DragPasteboardProvider = @MainActor () -> NSPasteboard
    /// Starts an AppKit session for a prepared dragging item.
    public typealias NativeDragStarter = @MainActor (
        _ sourceView: NSView,
        _ draggingItem: NSDraggingItem,
        _ event: NSEvent,
        _ source: any NSDraggingSource
    ) -> NSDraggingSession

    /// The generation-fenced session currently owned by the process.
    private(set) var currentSession: SidebarWorkspaceDragSession?
    /// The last token issued, retained after completion for generation checks.
    public private(set) var mostRecentSessionId: UUID?
    /// Workspace identity paired with ``mostRecentSessionId``.
    public private(set) var mostRecentWorkspaceId: UUID?
    private var nativeDragSources: [UUID: SidebarWorkspaceDragSessionSource] = [:]
    private var participants: [SidebarWorkspaceDragParticipantReference] = []
    private let dragPasteboardProvider: DragPasteboardProvider
    private let nativeDragStarter: NativeDragStarter

    deinit {}

    /// Creates an empty registry with no drag in flight.
    /// - Parameter dragPasteboardProvider: Source of the pasteboard used for
    ///   residual-capability cleanup. Tests can provide an isolated board.
    public init(
        dragPasteboardProvider: @escaping DragPasteboardProvider = {
            NSPasteboard(name: .drag)
        },
        nativeDragStarter: @escaping NativeDragStarter = { sourceView, draggingItem, event, source in
            sourceView.beginDraggingSession(
                with: [draggingItem],
                event: event,
                source: source
            )
        }
    ) {
        self.dragPasteboardProvider = dragPasteboardProvider
        self.nativeDragStarter = nativeDragStarter
    }

    /// The workspace represented by the current process-wide drag, if any.
    public var currentWorkspaceId: UUID? { currentSession?.workspaceId }

    /// The generation token for the current process-wide drag, if any.
    public var currentSessionId: UUID? { currentSession?.id }

    public func begin(workspaceId: UUID) {
        _ = beginSession(workspaceId: workspaceId)
    }

    public func end(workspaceId: UUID) {
        guard currentWorkspaceId == workspaceId else { return }
        endCurrentSession()
    }

    /// Begins a tokenized session, superseding any prior workspace drag.
    public func beginSession(workspaceId: UUID) -> SidebarWorkspaceDragSession {
        beginSession(workspaceId: workspaceId, reclaimNativeSources: false)
    }

    /// Begins a session after AppKit has crossed a native pointer boundary.
    public func beginNativeSession(workspaceId: UUID) -> SidebarWorkspaceDragSession {
        beginSession(workspaceId: workspaceId, reclaimNativeSources: true)
    }

    private func beginSession(
        workspaceId: UUID,
        reclaimNativeSources: Bool
    ) -> SidebarWorkspaceDragSession {
        if reclaimNativeSources {
            // AppKit cannot start this native session while an older source is
            // still in its drag loop, so reclaiming superseded holds is safe.
            reclaimAllNativeSourcesBeforeNewSession()
        }
        endCurrentSession()
        let session = SidebarWorkspaceDragSession(workspaceId: workspaceId)
        currentSession = session
        mostRecentSessionId = session.id
        mostRecentWorkspaceId = session.workspaceId
        return session
    }

    /// Resolves a live session for a matching workspace identity.
    public func session(matching workspaceId: UUID) -> SidebarWorkspaceDragSession? {
        guard currentSession?.workspaceId == workspaceId else { return nil }
        return currentSession
    }

    /// Starts and retains an AppKit source for a live session.
    public func beginNativeDragging(
        sessionId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage,
        capabilityValue: String
    ) -> Bool {
        guard currentSession?.id == sessionId else { return false }

        let payloadType = NSPasteboard.PasteboardType(
            SidebarWorkspaceDragSession.pasteboardTypeIdentifier
        )
        guard pasteboardItem.setString(capabilityValue, forType: payloadType) else {
            return false
        }
        // Materialize the same token on the process drag pasteboard before
        // AppKit begins delivering hit-tests. This removes the provider
        // materialization race while keeping the payload fenced to this
        // generation.
        let dragPasteboard = dragPasteboardProvider()
        dragPasteboard.clearContents()
        guard dragPasteboard.setString(capabilityValue, forType: payloadType) else {
            return false
        }
        let source = SidebarWorkspaceDragSessionSource(
            sessionId: sessionId,
            capabilityValue: capabilityValue,
            registry: self
        )
        nativeDragSources[sessionId] = source

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(draggingFrame, contents: dragImage)
        let dragSession = nativeDragStarter(sourceView, draggingItem, event, source)
        source.bind(sourceView: sourceView)
        dragSession.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }

    /// Releases source holds other than `excludingSessionId` after a pointer
    /// boundary. The explicit exclusion keeps a still-live native source owned
    /// when a table receives a new mouse-down during the same event turn.
    public func reclaimSupersededNativeSources(excludingSessionId: UUID) {
        reclaimNativeSources { $0 != excludingSessionId }
    }

    /// Handles the terminal callback from a native source or table controller.
    public func nativeDraggingSessionDidEnd(
        sessionId: UUID,
        capabilityValue: String
    ) {
        nativeDragSources[sessionId] = nil
        end(sessionId: sessionId)
        clearResidualCapability(capabilityValue)
    }

    /// Ends only the session whose generation token still matches.
    public func end(sessionId: UUID) {
        guard currentSession?.id == sessionId else { return }
        endCurrentSession()
    }

    /// Registers a window-local presentation for coordinated cleanup.
    public func register(_ state: SidebarDragState) {
        participants.removeAll { $0.state == nil || $0.state === state }
        participants.append(SidebarWorkspaceDragParticipantReference(state: state))
    }

    private func endCurrentSession() {
        guard let session = currentSession else { return }
        currentSession = nil
        let participantsSnapshot = participants
        for participant in participantsSnapshot {
            participant.state?.coordinatorDidEnd(sessionId: session.id)
        }
        participants.removeAll { $0.state == nil }
    }

    private func clearResidualCapability(_ capabilityValue: String) {
        let pasteboard = dragPasteboardProvider()
        let type = NSPasteboard.PasteboardType(
            SidebarWorkspaceDragSession.pasteboardTypeIdentifier
        )
        let currentValue = pasteboard.string(forType: type)
            ?? pasteboard.data(forType: type).flatMap { String(data: $0, encoding: .utf8) }
        guard currentValue == capabilityValue else { return }
        // A drag pasteboard can also carry a file or promised representation.
        // Do not destroy unrelated values merely because this session ended.
        guard (pasteboard.types ?? []).allSatisfy({ $0 == type }) else { return }
        pasteboard.clearContents()
    }

    private func reclaimAllNativeSourcesBeforeNewSession() {
        reclaimNativeSources { _ in true }
    }

    private func reclaimNativeSources(
        where shouldReclaim: (UUID) -> Bool
    ) {
        let supersededSources = nativeDragSources.filter { shouldReclaim($0.key) }.values
        for source in supersededSources {
            nativeDragSources[source.sessionIdentifier] = nil
            source.finishAfterNativeBoundary()
        }
    }
}
