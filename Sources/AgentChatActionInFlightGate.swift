import os

/// Owns one app-scoped agent-chat launch and serializes its lifecycle.
///
/// The lock protects only short state transitions; process signaling and exit
/// waits happen after the lock is released. The reference type is unchecked
/// sendable because every mutable field is protected by that lock and the
/// injected termination closures are sendable.
nonisolated final class AgentChatActionInFlightGate: @unchecked Sendable {
    /// Mutable launch state protected by ``lock``.
    struct State {
        var isRunning = false
        var terminationInProgress = false
        var terminationFailed = false
        var ownedServerSession: AgentChatOwnedServerSession?
        var ownedServerProcess: AgentChatSidecarProcessHandle?
        var sidecarStateFileStore = AgentChatSidecarStateFileStore.live()
        var terminationCompletion: AgentChatSidecarProcessExitCompletion?
    }

    typealias SessionTerminator = @Sendable (AgentChatOwnedServerSession) -> Bool
    typealias ProcessTerminator = @Sendable (AgentChatSidecarProcessHandle) -> Bool
    typealias AsyncSessionTerminator = @Sendable (AgentChatOwnedServerSession) async -> Bool

    // Synchronous AppKit/shutdown callbacks need one atomic compare-and-set;
    // an actor would introduce an await gap between the claim and ownership
    // snapshot. This lock is the low-level bridge only: process signaling
    // never runs while it is held. The test target accesses it through
    // @testable import rather than a production reset hook.
    nonisolated let lock: OSAllocatedUnfairLock<State>
    private let processTerminator: ProcessTerminator
    private let sessionTerminator: SessionTerminator
    private let asyncSessionTerminator: AsyncSessionTerminator

    /// Creates an empty gate for one app composition root.
    init(
        sidecarStateFileStore: AgentChatSidecarStateFileStore? = AgentChatSidecarStateFileStore.live(),
        processTerminator: @escaping ProcessTerminator = { process in
            process.terminate()
        },
        sessionTerminator: @escaping SessionTerminator = { session in
            AgentChatSidecarProcessTerminator().terminate(session: session)
        },
        asyncSessionTerminator: @escaping AsyncSessionTerminator = { session in
            guard let identity = session.processIdentity else { return false }
            let processID = identity.pid
            return await AgentChatSidecarProcessTerminator().terminateAsync(
                session: session,
                waitForExit: {
                    await AgentChatSidecarProcessTerminator.waitForProcessExit(
                        pid: processID,
                        identity: identity
                    )
                }
            )
        }
    ) {
        var state = State()
        state.sidecarStateFileStore = sidecarStateFileStore
        self.lock = OSAllocatedUnfairLock(initialState: state)
        self.processTerminator = processTerminator
        self.sessionTerminator = sessionTerminator
        self.asyncSessionTerminator = asyncSessionTerminator
    }

    /// Claims the gate for a new action, returning false while another action
    /// or an identity-safe termination transaction is in progress.
    func begin() -> Bool {
        lock.withLock { state in
            guard !state.isRunning, !state.terminationInProgress else { return false }
            state.isRunning = true
            return true
        }
    }

    /// Waits for a currently-running termination transaction to publish its result.
    func waitForTermination() async {
        while true {
            let completion = lock.withLock { state in
                state.terminationInProgress ? state.terminationCompletion : nil
            }
            guard let completion else { return }
            guard await completion.wait() else { return }
        }
    }

    /// Releases the action claim after the launch workflow finishes.
    func end() {
        lock.withLock { state in
            state.isRunning = false
        }
    }

    /// Returns the currently-owned state-file session, if any.
    func ownedServerSession() -> AgentChatOwnedServerSession? {
        lock.withLock { state in
            state.ownedServerSession
        }
    }

    /// Returns a launch handle that has not reached state-file discovery yet.
    func ownedServerProcess() -> AgentChatSidecarProcessHandle? {
        lock.withLock { state in
            state.ownedServerProcess
        }
    }

    private static func sameSessionIdentity(
        _ lhs: AgentChatOwnedServerSession,
        _ rhs: AgentChatOwnedServerSession
    ) -> Bool {
        // Launch IDs are canonical; legacy sessions without one only match
        // when their complete snapshots are identical.
        guard let lhsLaunchId = lhs.launchId,
              let rhsLaunchId = rhs.launchId else {
            return lhs == rhs
        }
        return lhsLaunchId == rhsLaunchId
    }

    private struct OwnedServerSnapshot: Sendable {
        let session: AgentChatOwnedServerSession?
        let process: AgentChatSidecarProcessHandle?
    }

    private enum OwnershipReplacement {
        case session(AgentChatOwnedServerSession)
        case process(AgentChatSidecarProcessHandle)
        case server(session: AgentChatOwnedServerSession, process: AgentChatSidecarProcessHandle)

        func needsPreviousTermination(in state: State) -> Bool {
            let previousSessionNeedsTermination: Bool
            if let previousSession = state.ownedServerSession {
                switch self {
                case .session(let session):
                    previousSessionNeedsTermination = !AgentChatActionInFlightGate.sameSessionIdentity(
                        previousSession,
                        session
                    )
                case .server(let session, let process):
                    previousSessionNeedsTermination =
                        !AgentChatActionInFlightGate.sameSessionIdentity(previousSession, session)
                        || previousSession.launchId != process.launchId
                case .process(let process):
                    previousSessionNeedsTermination = previousSession.launchId != process.launchId
                }
            } else {
                previousSessionNeedsTermination = false
            }

            let previousProcessNeedsTermination: Bool
            switch self {
            case .session(let session):
                previousProcessNeedsTermination = state.ownedServerProcess.map {
                    $0.launchId != session.launchId
                } ?? false
            case .process(let process), .server(_, let process):
                previousProcessNeedsTermination = state.ownedServerProcess.map {
                    $0 !== process
                } ?? false
            }
            return previousSessionNeedsTermination || previousProcessNeedsTermination
        }

        /// Applies a replacement only after the previous owner is proven gone.
        func apply(to state: inout State) {
            switch self {
            case .session(let session):
                if let previous = state.ownedServerProcess,
                   previous.launchId != session.launchId {
                    state.ownedServerProcess = nil
                }
                state.ownedServerSession = session
            case .process(let process):
                if let session = state.ownedServerSession,
                   session.launchId != process.launchId {
                    state.ownedServerSession = nil
                }
                state.ownedServerProcess = process
            case .server(let session, let process):
                state.ownedServerSession = session
                state.ownedServerProcess = process
            }
        }
    }

    private enum OwnershipUpdateResult {
        case retry(AgentChatSidecarProcessExitCompletion)
        case replace(OwnedServerSnapshot, AgentChatSidecarProcessExitCompletion)
        case applied
        case rejected
    }

    /// Records ownership without publishing a replacement before cleanup.
    @discardableResult
    func updateOwnedServerSession(_ session: AgentChatOwnedServerSession) async -> Bool {
        await updateOwnership(.session(session))
    }

    /// Records a newly-launched process without dropping it during cleanup.
    @discardableResult
    func updateOwnedServerProcess(_ process: AgentChatSidecarProcessHandle) async -> Bool {
        await updateOwnership(.process(process))
    }

    /// Atomically publishes a verified session after any prior termination.
    @discardableResult
    func updateOwnedServer(
        session: AgentChatOwnedServerSession,
        process: AgentChatSidecarProcessHandle
    ) async -> Bool {
        await updateOwnership(.server(session: session, process: process))
    }

    /// Serializes replacement cleanup and keeps failed ownership retryable.
    private func updateOwnership(_ replacement: OwnershipReplacement) async -> Bool {
        while true {
            let result = lock.withLock { state -> OwnershipUpdateResult in
                if state.terminationInProgress {
                    guard let completion = state.terminationCompletion else { return .rejected }
                    return .retry(completion)
                }
                guard !state.terminationFailed else { return .rejected }
                guard replacement.needsPreviousTermination(in: state) else {
                    replacement.apply(to: &state)
                    return .applied
                }
                let snapshot = OwnedServerSnapshot(
                    session: state.ownedServerSession,
                    process: state.ownedServerProcess
                )
                let completion = AgentChatSidecarProcessExitCompletion()
                state.terminationInProgress = true
                state.terminationFailed = false
                state.terminationCompletion = completion
                return .replace(snapshot, completion)
            }
            switch result {
            case .retry(let completion):
                guard await completion.wait() else {
                    terminateReplacementIfUnowned(replacement)
                    return false
                }
            case .rejected:
                terminateReplacementIfUnowned(replacement)
                return false
            case .applied:
                return true
            case .replace(let snapshot, let completion):
                let didTerminate = terminateSnapshot(snapshot)
                let applied = finishOwnershipReplacement(
                    snapshot,
                    replacement: replacement,
                    completion: completion,
                    didTerminate: didTerminate
                )
                if !applied { terminateReplacementIfUnowned(replacement) }
                return applied
            }
        }
    }

    /// Publishes one replacement result while the old snapshot is still locked.
    private func finishOwnershipReplacement(
        _ snapshot: OwnedServerSnapshot,
        replacement: OwnershipReplacement,
        completion: AgentChatSidecarProcessExitCompletion,
        didTerminate: Bool
    ) -> Bool {
        let result = lock.withLock { state -> Bool in
            guard state.terminationInProgress else { return false }
            state.terminationInProgress = false
            state.terminationCompletion = nil
            guard didTerminate,
                  state.ownedServerProcess === snapshot.process,
                  state.ownedServerSession == snapshot.session else {
                state.terminationFailed = true
                return false
            }
            state.terminationFailed = false
            replacement.apply(to: &state)
            return true
        }
        Task { await completion.finish(result) }
        return result
    }

    /// Prevents a rejected incoming handle from becoming an unowned child.
    private func terminateReplacementIfUnowned(_ replacement: OwnershipReplacement) {
        switch replacement {
        case .session(let session):
            let isOwned = lock.withLock { state in
                if let ownedSession = state.ownedServerSession,
                   Self.sameSessionIdentity(ownedSession, session) {
                    return true
                }
                return state.ownedServerProcess?.launchId == session.launchId
            }
            if !isOwned { _ = sessionTerminator(session) }
        case .process(let process), .server(_, let process):
            let isOwned = lock.withLock { state in
                state.ownedServerProcess === process
            }
            if !isOwned { _ = processTerminator(process) }
        }
    }

    /// Retains the legacy clear API while requiring identity-safe termination.
    func clearOwnedServerSession(matching candidate: AgentChatOwnedServerSession? = nil) {
        _ = terminateOwnedServer(matching: candidate)
    }

    /// Marks the current owner as terminating and returns an immutable snapshot.
    private func claimOwnedServer(
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
            // A replacement action can await the completion signal instead of
            // observing a transiently empty owner.
            state.terminationInProgress = true
            state.terminationFailed = false
            state.terminationCompletion = AgentChatSidecarProcessExitCompletion()
            return OwnedServerSnapshot(
                session: state.ownedServerSession,
                process: state.ownedServerProcess
            )
        }
    }

    /// Publishes termination completion and clears only the matching snapshot.
    private func finishOwnedServerTermination(
        _ snapshot: OwnedServerSnapshot,
        didTerminate: Bool
    ) {
        let completion = lock.withLock { state -> AgentChatSidecarProcessExitCompletion? in
            guard state.terminationInProgress else { return nil }
            state.terminationInProgress = false
            state.terminationFailed = !didTerminate
            let completion = state.terminationCompletion
            state.terminationCompletion = nil
            guard didTerminate else {
                // Fail closed: retaining the snapshot gives the next action a
                // chance to retry identity-safe cleanup.
                return completion
            }
            if let process = snapshot.process,
               state.ownedServerProcess === process {
                state.ownedServerProcess = nil
            }
            if let session = snapshot.session,
               state.ownedServerSession == session {
                state.ownedServerSession = nil
            }
            return completion
        }
        if let completion {
            Task { await completion.finish(didTerminate) }
        }
    }

    /// Runs synchronous cleanup for one claimed owner snapshot.
    private func terminateSnapshot(_ snapshot: OwnedServerSnapshot) -> Bool {
        if let process = snapshot.process {
            return processTerminator(process)
        }
        if let session = snapshot.session {
            // Legacy in-memory sessions still require persisted identity and a
            // process-group check; the injected closure owns that fallback.
            return sessionTerminator(session)
        }
        return false
    }

    /// Runs asynchronous cleanup for one claimed owner snapshot.
    private func terminateSnapshotAsync(_ snapshot: OwnedServerSnapshot) async -> Bool {
        if let process = snapshot.process {
            return await process.terminateAsync()
        }
        if let session = snapshot.session {
            return await asyncSessionTerminator(session)
        }
        return false
    }

    /// Terminates the owned launch and clears it only after completion.
    @discardableResult
    func terminateOwnedServer(
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

    /// Asynchronously terminates the owned launch without blocking its caller's actor.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    @discardableResult
    func terminateOwnedServerAsync(
        matching candidate: AgentChatOwnedServerSession? = nil,
        matchingLaunchID launchID: String? = nil
    ) async -> Bool {
        guard let snapshot = claimOwnedServer(
            matching: candidate,
            matchingLaunchID: launchID
        ) else { return false }
        let didTerminate = await terminateSnapshotAsync(snapshot)
        finishOwnedServerTermination(snapshot, didTerminate: didTerminate)
        return didTerminate
    }

    /// Performs best-effort synchronous cleanup during application termination.
    func terminateOwnedServer() {
        _ = terminateOwnedServer(matching: nil, matchingLaunchID: nil)
    }

    /// Returns the state-file store configured for this app-scoped owner.
    func sidecarStateFileStore() -> AgentChatSidecarStateFileStore? {
        lock.withLock { state in
            state.sidecarStateFileStore
        }
    }
}
