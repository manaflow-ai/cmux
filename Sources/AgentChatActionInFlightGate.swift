import os

/// Serializes app-owned agent-chat launches and keeps the process handle next
/// to the state-file session it vouches for.  The lock is intentionally only
/// held while copying/clearing this small state; process signaling happens
/// after the lock is released so a bounded wait cannot block action entry.
nonisolated struct AgentChatActionInFlightGate {
    private struct State {
        var isRunning = false
        var ownedServerSession: AgentChatOwnedServerSession?
        var ownedServerProcess: AgentChatSidecarProcessHandle?
        var sidecarStateFileStore = AgentChatSidecarStateFileStore.live()
    }

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

    /// Returns a launch handle that has not reached state-file discovery yet.
    /// A failed timeout can leave this process-only snapshot in the gate while
    /// its identity is retried; callers must not launch a replacement beside
    /// it.
    static func ownedServerProcess() -> AgentChatSidecarProcessHandle? {
        lock.withLock { state in
            state.ownedServerProcess
        }
    }

    static func updateOwnedServerSession(_ session: AgentChatOwnedServerSession) {
        let previous = lock.withLock { state -> AgentChatSidecarProcessHandle? in
            let previous = state.ownedServerProcess
            if previous?.launchId != session.launchId {
                state.ownedServerProcess = nil
            }
            state.ownedServerSession = session
            return previous
        }
        if previous?.launchId != session.launchId { previous?.terminate() }
    }

    static func updateOwnedServerProcess(_ process: AgentChatSidecarProcessHandle) {
        let previous = lock.withLock { state -> AgentChatSidecarProcessHandle? in
            let previous = state.ownedServerProcess
            if let session = state.ownedServerSession,
               session.launchId != process.launchId {
                state.ownedServerSession = nil
            }
            state.ownedServerProcess = process
            return previous
        }
        if previous !== process { previous?.terminate() }
    }

    /// Atomically associates the verified state-file session with its launch
    /// handle.  This closes the window where a timeout/replacement could see a
    /// PID but not the process identity captured at spawn.
    static func updateOwnedServer(
        session: AgentChatOwnedServerSession,
        process: AgentChatSidecarProcessHandle
    ) {
        let previous = lock.withLock { state -> AgentChatSidecarProcessHandle? in
            let previous = state.ownedServerProcess
            state.ownedServerSession = session
            state.ownedServerProcess = process
            return previous
        }
        if previous !== process { previous?.terminate() }
    }

    static func clearOwnedServerSession(matching candidate: AgentChatOwnedServerSession? = nil) {
        // Keep the legacy API safe for callers that only know about the
        // session: ownership is cleared only after identity-safe termination.
        _ = terminateOwnedServer(matching: candidate)
    }

    /// Test fixtures that model a session without a live process handle must
    /// be able to reset the process-global gate.  Production cleanup goes
    /// through `terminateOwnedServer`; this hook is intentionally separate so
    /// a fixture cannot accidentally turn an unknown PID into a kill target.
    static func resetForTesting() {
        lock.withLock { state in
            state.ownedServerSession = nil
            state.ownedServerProcess = nil
            state.isRunning = false
        }
    }

    /// Takes ownership out of the gate before signaling.  A candidate (when
    /// supplied) prevents a late theme/recovery callback from terminating a
    /// newer launch that replaced the one it observed.
    @discardableResult
    static func terminateOwnedServer(
        matching candidate: AgentChatOwnedServerSession? = nil,
        matchingLaunchID launchID: String? = nil
    ) -> Bool {
        let snapshot = lock.withLock { state -> (
            session: AgentChatOwnedServerSession?,
            process: AgentChatSidecarProcessHandle?
        )? in
            if let candidate, state.ownedServerSession != candidate { return nil }
            if let candidate,
               let processLaunchId = state.ownedServerProcess?.launchId,
               processLaunchId != candidate.launchId {
                return nil
            }
            if let launchID,
               state.ownedServerProcess?.launchId != launchID,
               state.ownedServerSession?.launchId != launchID {
                return nil
            }
            let snapshot = (state.ownedServerSession, state.ownedServerProcess)
            state.ownedServerSession = nil
            state.ownedServerProcess = nil
            return snapshot
        }
        guard let snapshot,
              snapshot.session != nil || snapshot.process != nil else {
            return false
        }
        let didTerminate: Bool
        if let process = snapshot.process {
            didTerminate = process.terminate()
            if !didTerminate {
                // The process identity changed between the snapshot and the
                // signal attempt. Restore the handle so a later action can
                // retry instead of launching alongside an unknown process.
                lock.withLock { state in
                    guard state.ownedServerSession == nil,
                          state.ownedServerProcess == nil else { return }
                    state.ownedServerSession = snapshot.session
                    state.ownedServerProcess = process
                }
            }
        } else if let session = snapshot.session {
            // Legacy in-memory sessions do not have a launch handle.  The
            // fallback still requires the persisted kernel start token and
            // process-group identity; it never signals a bare PID.
            didTerminate = AgentChatSidecarProcessTerminator().terminate(session: session)
            if !didTerminate {
                // Keep the session visible when its identity is missing or
                // stale.  Forgetting it here would permit a replacement launch
                // beside an unknown process.
                lock.withLock { state in
                    guard state.ownedServerSession == nil,
                          state.ownedServerProcess == nil else { return }
                    state.ownedServerSession = session
                }
            }
        } else {
            didTerminate = false
        }
        return didTerminate
    }

    /// Recovery runs from MainActor tasks, but termination includes a bounded
    /// synchronous grace period.  Keep that wait off the UI actor; app quit
    /// uses the synchronous overload below because there is no async turn left
    /// to await.
    static func terminateOwnedServerAsync(
        matching candidate: AgentChatOwnedServerSession? = nil,
        matchingLaunchID launchID: String? = nil
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            terminateOwnedServer(matching: candidate, matchingLaunchID: launchID)
        }.value
    }

    /// Used by app termination, where there is no async turn in which to wait
    /// for cleanup.  Identity failure keeps the snapshot retained and sends
    /// no signal, preserving the fail-closed invariant until the process exits.
    static func terminateOwnedServer() {
        _ = terminateOwnedServer(matching: nil, matchingLaunchID: nil)
    }

    static func sidecarStateFileStore() -> AgentChatSidecarStateFileStore? {
        lock.withLock { state in
            state.sidecarStateFileStore
        }
    }
}
