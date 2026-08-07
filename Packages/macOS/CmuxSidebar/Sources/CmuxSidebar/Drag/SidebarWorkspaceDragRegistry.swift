public import Foundation
import CoreGraphics

/// Immutable identity for one process-wide workspace drag.
struct SidebarWorkspaceDragSession: Equatable, Sendable {
    let id: UUID
    let workspaceId: UUID

    init(id: UUID = UUID(), workspaceId: UUID) {
        self.id = id
        self.workspaceId = workspaceId
    }
}

/// Process-wide coordinator for the workspace currently being dragged in any
/// window's sidebar.
///
/// The coordinator owns the session token, lifecycle monitor, and weak set of
/// source/mirror presentation states. A lifecycle exit clears the token and all
/// matching window-local state together, so no view callback is the sole owner
/// of process-wide cleanup.
@MainActor
public final class SidebarWorkspaceDragRegistry {
    private struct WeakParticipant {
        weak var state: SidebarDragState?
    }

    private(set) var currentSession: SidebarWorkspaceDragSession?
    private let isLeftMouseButtonPressed: @MainActor () -> Bool
    private var lifecycleMonitor: SidebarWorkspaceDragLifecycleMonitor?
    private var participants: [WeakParticipant] = []

    /// Creates an empty registry with no drag in flight.
    public convenience init() {
        self.init(isLeftMouseButtonPressed: {
            CGEventSource.buttonState(.combinedSessionState, button: .left)
        })
    }

    /// Creates a registry with an injected physical-button state source.
    init(isLeftMouseButtonPressed: @escaping @MainActor () -> Bool) {
        self.isLeftMouseButtonPressed = isLeftMouseButtonPressed
    }

    /// The workspace participating in the active process-wide drag, if any.
    public var currentWorkspaceId: UUID? { currentSession?.workspaceId }

    @discardableResult
    func begin(
        workspaceId: UUID,
        monitorLifecycle: Bool = true
    ) -> SidebarWorkspaceDragSession {
        endCurrentSession()
        let session = SidebarWorkspaceDragSession(workspaceId: workspaceId)
        currentSession = session
        if monitorLifecycle {
            let monitor = SidebarWorkspaceDragLifecycleMonitor(
                sessionId: session.id,
                isLeftMouseButtonPressed: isLeftMouseButtonPressed
            ) { [weak self] sessionId in
                self?.end(sessionId: sessionId)
            }
            lifecycleMonitor = monitor
            monitor.start()
        }
        return session
    }

    func end(sessionId: UUID) {
        guard currentSession?.id == sessionId else { return }
        endCurrentSession()
    }

    func register(_ state: SidebarDragState) {
        participants.removeAll { $0.state == nil || $0.state === state }
        participants.append(WeakParticipant(state: state))
    }

    private func endCurrentSession() {
        guard let session = currentSession else {
            lifecycleMonitor?.stop()
            lifecycleMonitor = nil
            return
        }
        currentSession = nil
        lifecycleMonitor?.stop()
        lifecycleMonitor = nil
        let participantsSnapshot = participants
        for participant in participantsSnapshot {
            guard let state = participant.state else { continue }
            state.coordinatorDidEnd(sessionId: session.id)
        }
        participants.removeAll { $0.state == nil }
    }
}
