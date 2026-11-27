public import CmuxNextDaemon
import Foundation

// The create path of a new workspace (Cmd-N): what the app asks the daemon service around it.
extension DaemonService {
    /// Whether the next Cmd-N's workspace may be reserved now (`DaemonStore.reserveWorkspace`): connected, loaded, and
    /// not paused by memory pressure.
    public var reservesWorkspace: Bool { connection != nil && store.isLoaded && !store.reservationPaused }

    /// The check that this daemon's store has applied every event before now (a create's reply): a write barrier
    /// taken without waiting for it.
    public func settledCheck() async -> @MainActor () -> Bool {
        guard let barrier = await connection?.eventSequence() else { return { false } }
        let store = store
        return { store.appliedSequence >= barrier }
    }
}
