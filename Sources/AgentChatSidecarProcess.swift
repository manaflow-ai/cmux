import Darwin
import Foundation
import os

/// A launch-scoped process-group handle for an app-owned agent-chat sidecar.
/// The class is `@unchecked Sendable` because its mutable fields are guarded
/// by the short synchronous lock below; the process itself is only touched by
/// POSIX calls and the dispatch exit source.
nonisolated final class AgentChatSidecarProcessHandle: @unchecked Sendable {
    let launchId: String
    let rootIdentity: AgentPIDProcessIdentity
    let processGroupID: pid_t

    private struct State {
        var serverIdentity: AgentPIDProcessIdentity?
        var terminationStarted = false
        var terminationCompleted = false
        var rootExited = false
    }

    // Short compare-and-set only: Process/DispatchSource callbacks can race
    // with app termination, while the bounded signal wait stays outside it.
    private let lock: OSAllocatedUnfairLock<State>
    private let exitSource: DispatchSourceProcess
    private let exitCompletion: AgentChatSidecarProcessExitCompletion

    /// Creates a handle for the child-led process group identified at launch.
    init(
        launchId: String,
        rootIdentity: AgentPIDProcessIdentity,
        processGroupID: pid_t
    ) {
        self.launchId = launchId
        self.rootIdentity = rootIdentity
        self.processGroupID = processGroupID
        self.lock = OSAllocatedUnfairLock(initialState: State())
        self.exitCompletion = AgentChatSidecarProcessExitCompletion()

        // DispatchSource is the only non-polling process-exit callback at this
        // POSIX seam; it lets us reap the child without a background waiter.
        let source = DispatchSource.makeProcessSource(
            identifier: rootIdentity.pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        self.exitSource = source
        source.setEventHandler { [weak self] in
            // Leave the zombie unreaped until termination. Its PID and process
            // group remain reserved, giving timeout cleanup a safe anchor even
            // when the sidecar never published a state-file PID.
            self?.rootDidExit()
        }
        source.resume()
    }

    deinit {
        // Dropping the last owner must not detach a live app-owned process.
        // `terminate` is idempotent and still performs the same identity
        // checks before it can signal the launch group.
        let didTerminate = terminate()
        exitSource.cancel()
        if !didTerminate {
            // A synchronous deinit cannot await the process-source event. A
            // fresh direct-child proof lets this last-resort path kill and
            // reap the exact child without trusting a recyclable PID.
            Self.scheduleDirectChildTermination(rootIdentity)
        }
    }

    /// Captures and validates the server PID reported by the state file.  A
    /// state file is accepted only when its PID is the same process generation
    /// and remains in the process group created for this launch.
    func verifiedSession(
        from session: AgentChatOwnedServerSession
    ) -> AgentChatOwnedServerSession? {
        guard (session.launchId == nil || session.launchId == launchId),
              (1...Int(Int32.max)).contains(session.pid),
              let identity = AgentPIDProcessIdentity(pid: pid_t(session.pid)),
              identity.pid == pid_t(session.pid),
              AgentPIDProcessIdentity.processGroupID(pid: identity.pid) == processGroupID else {
            return nil
        }
        let accepted = lock.withLock { state -> Bool in
            guard !state.terminationStarted else { return false }
            state.serverIdentity = identity
            return true
        }
        guard accepted else { return nil }
        // Keep the child-led root unreaped while this handle is owned.  The
        // zombie (when the shell leader exits first) pins the process-group ID
        // so a later timeout can still signal descendants that never made it
        // into the state file.  It is reaped after a successful termination or
        // when the handle is finally released.
        var verified = session
        verified.launchId = launchId
        verified.processIdentity = identity
        verified.processGroupID = processGroupID
        return verified
    }

    /// Sends SIGTERM, revalidates, and escalates immediately when this
    /// synchronous shutdown/deinit path has no async turn to await. Both
    /// signals target the launch process group, and every signal is gated by a
    /// PID/start-time identity check plus a current process-group check. The
    /// recovery path uses `terminateAsync()` to give SIGTERM its grace window.
    @discardableResult
    func terminate() -> Bool {
        let identities = lock.withLock { state -> [AgentPIDProcessIdentity]? in
            if state.terminationCompleted { return [] }
            guard !state.terminationStarted else { return nil }
            state.terminationStarted = true
            var values = [rootIdentity]
            if let serverIdentity = state.serverIdentity,
               serverIdentity != rootIdentity {
                values.append(serverIdentity)
            }
            return values
        }
        // A completed termination is idempotently successful.  A concurrent
        // termination is not: callers must retain ownership until that first
        // attempt publishes its result instead of launching a replacement.
        guard let identities else { return false }
        guard !identities.isEmpty else { return true }
        let didTerminate = AgentChatSidecarProcessTerminator(
            identityProvider: { pid in
                if pid == self.rootIdentity.pid {
                    // A zombie cannot be reused until this parent reaps it, so
                    // one process-table read can preserve its captured birth
                    // token across the live-to-zombie transition.
                    return AgentPIDProcessIdentity.includingExitedProcess(pid: pid)
                }
                return AgentPIDProcessIdentity(pid: pid)
            }
        ).terminate(
            identities: identities,
            processGroupID: processGroupID
        )
        // Reap an already-exited root even when identity validation rejected
        // the signal. This does not claim group cleanup; it only releases the
        // direct-child status that this handle still owns.
        let rootReaped = reapRootIfExited()
        lock.withLock { state in
            state.terminationStarted = false
            if didTerminate && rootReaped {
                state.terminationCompleted = true
            }
        }
        return didTerminate && rootReaped
    }

    /// Performs the recovery termination without blocking a cooperative
    /// executor thread. The process-exit source wakes the grace-period race;
    /// the terminator still revalidates every captured identity before any
    /// escalation signal.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    @discardableResult
    func terminateAsync() async -> Bool {
        let identities = lock.withLock { state -> [AgentPIDProcessIdentity]? in
            if state.terminationCompleted { return [] }
            guard !state.terminationStarted else { return nil }
            state.terminationStarted = true
            var values = [rootIdentity]
            if let serverIdentity = state.serverIdentity,
               serverIdentity != rootIdentity {
                values.append(serverIdentity)
            }
            return values
        }
        guard let identities else { return false }
        guard !identities.isEmpty else { return true }

        let didTerminate = await AgentChatSidecarProcessTerminator(
            identityProvider: { pid in
                if pid == self.rootIdentity.pid {
                    // A zombie cannot be reused until this parent reaps it,
                    // so retain its generation as the group anchor.
                    return AgentPIDProcessIdentity.includingExitedProcess(pid: pid)
                }
                return AgentPIDProcessIdentity(pid: pid)
            }
        ).terminateAsync(
            identities: identities,
            processGroupID: processGroupID,
            waitForExit: { [exitCompletion] in
                await exitCompletion.wait()
            }
        )
        let rootReaped: Bool
        if didTerminate {
            // SIGKILL being accepted only proves that the signal was queued;
            // keep ownership until the process source reports exit and the
            // direct child has actually been reaped.
            rootReaped = await waitForRootExitAndReap()
        } else {
            // A failed signal may race a natural root exit. Reap that direct
            // child when possible, but retain the lifecycle owner because the
            // process group was not proven clean.
            rootReaped = reapRootIfExited()
        }
        lock.withLock { state in
            state.terminationStarted = false
            if didTerminate && rootReaped {
                state.terminationCompleted = true
            }
        }
        return didTerminate && rootReaped
    }

    /// Attempts one non-blocking reap of the owned root process.
    /// Returning false means the child is still live; callers retain ownership
    /// and may await the process-source completion before trying again.
    @discardableResult
    private func reapRootIfExited() -> Bool {
        var status: Int32 = 0
        while true {
            let result = waitpid(rootIdentity.pid, &status, WNOHANG)
            if result == rootIdentity.pid || (result == -1 && errno == ECHILD) { return true }
            if result == 0 { return false }
            if result == -1 && errno == EINTR { continue }
            return false
        }
    }

    /// Waits for the process-source event and then reaps the owned root.
    private func waitForRootExitAndReap() async -> Bool {
        if reapRootIfExited() { return true }
        guard await exitCompletion.wait() else { return false }
        return reapRootIfExited()
    }

    /// Installs a process-exit watcher for a direct child without blocking a
    /// cooperative executor thread. Register it before signaling a suspended
    /// child so an already-queued exit cannot outrun observation.
    private static func installDirectChildExitWatcher(
        _ processIdentifier: pid_t,
        completion: AgentChatSidecarProcessExitCompletion
    ) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            source.cancel()
            Task { await completion.finish(true) }
        }
        source.resume()
        return source
    }

    /// Terminates and reaps a suspended direct child after proving ownership.
    /// An optional identity is checked before selecting the process-group
    /// target; the direct-child waitpid proof remains the fallback when that
    /// token is absent or conflicts.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    @discardableResult
    static func terminateDirectChild(
        _ processIdentifier: pid_t,
        expectedIdentity: AgentPIDProcessIdentity? = nil
    ) async -> Bool {
        var status: Int32 = 0
        let waitResult: pid_t
        while true {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == -1 && errno == EINTR { continue }
            waitResult = result
            break
        }
        if waitResult == processIdentifier || (waitResult == -1 && errno == ECHILD) {
            return true
        }
        guard waitResult == 0 else { return false }
        let identityMatchesExpected: Bool
        if let expectedIdentity {
            identityMatchesExpected = AgentPIDProcessIdentity.includingExitedProcess(
                pid: processIdentifier
            ) == expectedIdentity
        } else {
            identityMatchesExpected = true
        }
        // The direct-child proof means this PID cannot have been recycled
        // until this parent reaps it. A conflicting token therefore disables
        // only the group target; the positive PID remains this child.
        let completion = AgentChatSidecarProcessExitCompletion()
        let source = installDirectChildExitWatcher(
            processIdentifier,
            completion: completion
        )
        defer { source.cancel() }
        let groupID = identityMatchesExpected ? Darwin.getpgid(processIdentifier) : -1
        let target = identityMatchesExpected && groupID == processIdentifier
            ? -processIdentifier
            : processIdentifier
        errno = 0
        let signalResult = Darwin.kill(target, SIGKILL)
        if signalResult != 0 {
            let groupFailure = errno
            if target < 0 {
                guard groupFailure == ESRCH || groupFailure == EPERM else {
                    source.cancel()
                    return false
                }
                // Preserve the direct-child proof if the group vanished or
                // rejected the signal during the handoff; this avoids leaving a
                // stopped child behind.
                errno = 0
                let directResult = Darwin.kill(processIdentifier, SIGKILL)
                if directResult != 0, errno != ESRCH {
                    source.cancel()
                    return false
                }
            } else if groupFailure != ESRCH {
                source.cancel()
                return false
            }
        }
        while true {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            let waitFailure = errno
            if result == -1 && waitFailure == EINTR { continue }
            guard result == 0 else {
                source.cancel()
                if result == processIdentifier || (result == -1 && waitFailure == ECHILD) {
                    return true
                }
                return false
            }
            break
        }
        // The source reports the real exit event; only then can this helper
        // perform the final direct-child reap before returning.
        guard await completion.wait() else { return false }
        while true {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier || (result == -1 && errno == ECHILD) {
                return true
            }
            if result == -1 && errno == EINTR { continue }
            // NOTE_EXIT means the child is no longer running; if the status
            // has not become reapable yet, leave ownership failed-closed for
            // the caller's next identity-safe cleanup attempt rather than
            // spinning a cooperative executor thread.
            return false
        }
    }

    /// Schedules the shared async cleanup from the synchronous deinit boundary.
    private static func scheduleDirectChildTermination(_ identity: AgentPIDProcessIdentity) {
        Task.detached(priority: .utility) {
            _ = await AgentChatSidecarProcessHandle.terminateDirectChild(
                identity.pid,
                expectedIdentity: identity
            )
        }
    }

    /// Completes exit waiters when the dispatch process source fires.
    private func rootDidExit() {
        let shouldReap = lock.withLock { state -> Bool in
            state.rootExited = true
            return state.terminationCompleted
        }
        Task { [exitCompletion] in
            await exitCompletion.finish(true)
        }
        if shouldReap { reapRootIfExited() }
    }
}
