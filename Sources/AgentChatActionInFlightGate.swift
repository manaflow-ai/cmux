import os

/// Serializes app-owned agent-chat launches and keeps the process handle next
/// to the state-file session it vouches for.  The lock is intentionally only
/// held while copying/clearing this small state; process signaling happens
/// after the lock is released so a bounded wait cannot block action entry.
nonisolated struct AgentChatActionInFlightGate {
    /// The state is internal so the test target can reset fixtures through
    /// `@testable import` without adding a production-only test hook.
    struct State {
        var isRunning = false
        var terminationInProgress = false
        var ownedServerSession: AgentChatOwnedServerSession?
        var ownedServerProcess: AgentChatSidecarProcessHandle?
        var sidecarStateFileStore = AgentChatSidecarStateFileStore.live()
    }

    // Synchronous action entry and theme callbacks need one atomic transition;
    // the test target accesses this lock directly through @testable import so
    // production source does not grow a resetForTesting seam.
    nonisolated static let lock = OSAllocatedUnfairLock(initialState: State())

    static func begin() -> Bool {
        lock.withLock { state in
            guard !state.isRunning, !state.terminationInProgress else { return false }
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
            guard !state.terminationInProgress else { return nil }
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
            guard !state.terminationInProgress else { return nil }
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
            guard !state.terminationInProgress else { return nil }
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

    private struct OwnedServerSnapshot: @unchecked Sendable {
        let session: AgentChatOwnedServerSession?
        let process: AgentChatSidecarProcessHandle?
    }

    private static func claimOwnedServer(
        matching candidate: AgentChatOwnedServerSession?,
        matchingLaunchID launchID: String?
    ) -> OwnedServerSnapshot? {
        lock.withLock { state in
            guard !state.terminationInProgress else { return nil }
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
            guard state.ownedServerSession != nil || state.ownedServerProcess != nil else {
                return nil
            }
            // Keep both snapshots in the gate while process termination runs.
            // New Agent Chat actions observe this bit and cannot launch beside
            // a sidecar whose SIGTERM/SIGKILL transaction is still pending.
            state.terminationInProgress = true
            return OwnedServerSnapshot(
                session: state.ownedServerSession,
                process: state.ownedServerProcess
            )
        }
    }

    private static func finishOwnedServerTermination(
        _ snapshot: OwnedServerSnapshot,
        didTerminate: Bool
    ) {
        lock.withLock { state in
            guard state.terminationInProgress else { return }
            state.terminationInProgress = false
            guard didTerminate else {
                // Fail closed: retaining the snapshot gives the next action a
                // chance to retry identity-safe cleanup instead of launching
                // beside an unknown process.
                return
            }
            if let process = snapshot.process,
               state.ownedServerProcess === process {
                state.ownedServerProcess = nil
            }
            if let session = snapshot.session,
               state.ownedServerSession == session {
                state.ownedServerSession = nil
            }
        }
    }

    private static func terminateSnapshot(_ snapshot: OwnedServerSnapshot) -> Bool {
        if let process = snapshot.process {
            return process.terminate()
        }
        if let session = snapshot.session {
            // Legacy in-memory sessions do not have a launch handle. The
            // fallback still requires the persisted kernel start token and
            // process-group identity; it never signals a bare PID.
            return AgentChatSidecarProcessTerminator().terminate(session: session)
        }
        return false
    }

    /// Takes ownership out of the gate before signaling.  A candidate (when
    /// supplied) prevents a late theme/recovery callback from terminating a
    /// newer launch that replaced the one it observed.
    @discardableResult
    static func terminateOwnedServer(
        matching candidate: AgentChatOwnedServerSession? = nil,
        matchingLaunchID launchID: String? = nil
    ) -> Bool {
        guard let snapshot = claimOwnedServer(
            matching: candidate,
            matchingLaunchID: launchID
        ) else { return false }
        let didTerminate = terminateSnapshot(snapshot)
        finishOwnedServerTermination(snapshot, didTerminate: didTerminate)
        return didTerminate
    }

    /// Recovery runs from MainActor tasks, but termination includes a bounded
    /// synchronous grace period.  Keep that wait off the UI actor; app quit
    /// uses the synchronous overload below because there is no async turn left
    /// to await.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    static func terminateOwnedServerAsync(
        matching candidate: AgentChatOwnedServerSession? = nil,
        matchingLaunchID launchID: String? = nil
    ) async -> Bool {
        guard let snapshot = claimOwnedServer(
            matching: candidate,
            matchingLaunchID: launchID
        ) else { return false }
        let didTerminate = await Task.detached(priority: .utility) {
            terminateSnapshot(snapshot)
        }.value
        finishOwnedServerTermination(snapshot, didTerminate: didTerminate)
        return didTerminate
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
