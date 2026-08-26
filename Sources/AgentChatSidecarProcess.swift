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

    init(
        launchId: String,
        rootIdentity: AgentPIDProcessIdentity,
        processGroupID: pid_t
    ) {
        self.launchId = launchId
        self.rootIdentity = rootIdentity
        self.processGroupID = processGroupID
        self.lock = OSAllocatedUnfairLock(initialState: State())

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
        if didTerminate {
            reapRootIfExited()
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

    /// Sends SIGTERM, waits briefly for the validated launch to exit, then
    /// revalidates before SIGKILL.  Both signals target the launch process
    /// group, and every signal is gated by a PID/start-time identity check plus
    /// a current process-group check.  A stale or incomplete session receives
    /// no signal at all.
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
        lock.withLock { state in
            state.terminationStarted = false
            if didTerminate {
                state.terminationCompleted = true
            }
        }
        if didTerminate {
            // The exit callback covers a root that transitions after the
            // bounded signal operation; this immediate attempt covers one
            // that exited before the callback was delivered.
            reapRootIfExited()
        }
        return didTerminate
    }

    private func reapRootIfExited() {
        var status: Int32 = 0
        while true {
            let result = waitpid(rootIdentity.pid, &status, WNOHANG)
            if result == rootIdentity.pid || result == 0 { return }
            if result == -1 && errno == EINTR { continue }
            return
        }
    }

    private func rootDidExit() {
        let shouldReap = lock.withLock { state -> Bool in
            state.rootExited = true
            return state.terminationCompleted
        }
        if shouldReap { reapRootIfExited() }
    }
}
