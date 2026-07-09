import CMUXAgentLaunch
import os

nonisolated struct AgentChatActionInFlightGate {
    private struct State {
        var isRunning = false
        var ownedServerSession: AgentChatOwnedServerSession?
        var sidecarStateFileStore = AgentChatSidecarStateFileStore.live()
    }

    // Synchronous action entry and theme callbacks require one atomic state transition without Task scheduling.
    private nonisolated static let lock = OSAllocatedUnfairLock(initialState: State())

    static func begin() -> Bool {
        lock.withLock { state in
            guard !state.isRunning else { return false }
            state.isRunning = true
            return true
        }
    }

    static func end() {
        lock.withLock { state in
            state.isRunning = false
        }
    }

    static func ownedServerSession() -> AgentChatOwnedServerSession? {
        lock.withLock { state in
            state.ownedServerSession
        }
    }

    static func updateOwnedServerSession(_ session: AgentChatOwnedServerSession) {
        lock.withLock { state in
            state.ownedServerSession = session
        }
    }

    static func clearOwnedServerSession(matching candidate: AgentChatOwnedServerSession? = nil) {
        lock.withLock { state in
            if let candidate, state.ownedServerSession != candidate { return }
            state.ownedServerSession = nil
        }
    }

    static func sidecarStateFileStore() -> AgentChatSidecarStateFileStore? {
        lock.withLock { state in
            state.sidecarStateFileStore
        }
    }
}
