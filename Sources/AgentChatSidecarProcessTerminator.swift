import Darwin
import Foundation

/// Identity-checked, bounded termination shared by app-owned agent-chat
/// recovery, timeout cleanup, and application shutdown.
nonisolated struct AgentChatSidecarProcessTerminator {
    private enum IdentityValidation {
        case matching
        case gone
        case reused
    }

    typealias IdentityProvider = (pid_t) -> AgentPIDProcessIdentity?
    typealias ProcessGroupProvider = (pid_t) -> pid_t
    typealias ProcessGroupExistsProvider = (pid_t) -> Bool
    typealias SignalSender = (pid_t, Int32) -> Int32
    typealias GracePeriodWaiter = @Sendable (Duration) async -> Bool

    private let identityProvider: IdentityProvider
    private let processGroupProvider: ProcessGroupProvider
    private let processGroupExistsProvider: ProcessGroupExistsProvider
    private let signalSender: SignalSender
    private let gracePeriodWaiter: GracePeriodWaiter
    private static let terminationGracePeriod: Duration = .milliseconds(400)

    /// Creates a terminator with injectable kernel-operation and deadline seams.
    init(
        identityProvider: @escaping IdentityProvider = { AgentPIDProcessIdentity(pid: $0) },
        processGroupProvider: @escaping ProcessGroupProvider = {
            AgentPIDProcessIdentity.processGroupID(pid: $0) ?? Darwin.getpgid($0)
        },
        processGroupExistsProvider: @escaping ProcessGroupExistsProvider = { processGroupID in
            guard processGroupID > 1 else { return false }
            errno = 0
            let result = Darwin.kill(-processGroupID, 0)
            return result == 0 || errno == EPERM
        },
        signalSender: @escaping SignalSender = { Darwin.kill($0, $1) },
        gracePeriodWaiter: @escaping GracePeriodWaiter = { duration in
            await AgentChatSidecarProcessTerminator.waitForGracePeriod(duration)
        }
    ) {
        self.identityProvider = identityProvider
        self.processGroupProvider = processGroupProvider
        self.processGroupExistsProvider = processGroupExistsProvider
        self.signalSender = signalSender
        self.gracePeriodWaiter = gracePeriodWaiter
    }

    /// Terminates a validated process group synchronously for shutdown paths.
    func terminate(
        identities: [AgentPIDProcessIdentity],
        processGroupID: pid_t
    ) -> Bool {
        guard processGroupID > 1, !identities.isEmpty else { return false }
        let initialValidation = identities.map {
            validation(
                identity: $0,
                processGroupID: processGroupID
            )
        }
        guard !initialValidation.contains(.reused) else {
            // A generation mismatch anywhere in the launch makes the group
            // unsafe to address.  Even if another captured PID still matches,
            // that PID could have been recycled into (or joined) this group;
            // fail closed rather than risk signaling an unrelated process.
            return false
        }
        guard initialValidation.contains(.matching) else {
            // A completely exited launch is already clean.  A PID that now
            // names another generation is not cleanable by this snapshot. Do
            // not call it clean while an unanchored process group still
            // exists: that would permit descendants to survive unnoticed.
            return initialValidation.allSatisfy({ $0 == .gone })
                && !processGroupExistsProvider(processGroupID)
        }
        guard signalIfValidated(
            identities: identities,
            processGroupID: processGroupID,
            signal: SIGTERM,
            identityProvider: identityProvider,
            processGroupProvider: processGroupProvider,
            processGroupExistsProvider: processGroupExistsProvider,
            signalSender: signalSender
        ) else {
            return false
        }

        // The synchronous path is used only at app quit/deinit. Revalidate
        // immediately before escalation rather than blocking a caller on a
        // wall-clock grace period; the async path below waits on process exit.
        let finalValidation = identities.map {
            validation(
                identity: $0,
                processGroupID: processGroupID
            )
        }
        if finalValidation.contains(.reused) {
            return false
        }
        if finalValidation.allSatisfy({ $0 == .gone })
            && !processGroupExistsProvider(processGroupID) {
            return true
        }
        return signalIfValidated(
            identities: identities,
            processGroupID: processGroupID,
            signal: SIGKILL,
            identityProvider: identityProvider,
            processGroupProvider: processGroupProvider,
            processGroupExistsProvider: processGroupExistsProvider,
            signalSender: signalSender
        )
    }

    /// Terminates a launch while allowing its root process to run its SIGTERM
    /// disposal transaction. The wait is driven by a process-exit signal or a
    /// cancellation-aware deadline; no thread is blocked polling the process
    /// table.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    /// Terminates a validated process group while awaiting its exit signal.
    func terminateAsync(
        identities: [AgentPIDProcessIdentity],
        processGroupID: pid_t,
        waitForExit: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard processGroupID > 1, !identities.isEmpty else { return false }
        let initialValidation = identities.map {
            validation(
                identity: $0,
                processGroupID: processGroupID
            )
        }
        guard !initialValidation.contains(.reused) else { return false }
        guard initialValidation.contains(.matching) else {
            return initialValidation.allSatisfy({ $0 == .gone })
                && !processGroupExistsProvider(processGroupID)
        }
        guard signalIfValidated(
            identities: identities,
            processGroupID: processGroupID,
            signal: SIGTERM,
            identityProvider: identityProvider,
            processGroupProvider: processGroupProvider,
            processGroupExistsProvider: processGroupExistsProvider,
            signalSender: signalSender
        ) else {
            return false
        }

        let gracePeriodWaiter = self.gracePeriodWaiter
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waitForExit()
            }
            group.addTask { await gracePeriodWaiter(Self.terminationGracePeriod) }
            _ = await group.next()
            group.cancelAll()
        }

        // Revalidate immediately before escalating. Never issue SIGKILL from
        // a stale PID/group snapshot after a PID has been recycled.
        let finalValidation = identities.map {
            validation(
                identity: $0,
                processGroupID: processGroupID
            )
        }
        if finalValidation.contains(.reused) { return false }
        if finalValidation.allSatisfy({ $0 == .gone })
            && !processGroupExistsProvider(processGroupID) {
            return true
        }
        return signalIfValidated(
            identities: identities,
            processGroupID: processGroupID,
            signal: SIGKILL,
            identityProvider: identityProvider,
            processGroupProvider: processGroupProvider,
            processGroupExistsProvider: processGroupExistsProvider,
            signalSender: signalSender
        )
    }

    @discardableResult
    /// Terminates a session only when it carries a complete identity snapshot.
    func terminate(session: AgentChatOwnedServerSession) -> Bool {
        guard let identity = session.processIdentity,
              let processGroupID = session.processGroupID,
              (1...Int(Int32.max)).contains(session.pid),
              identity.pid == pid_t(session.pid) else {
            return false
        }
        return terminate(
            identities: [identity],
            processGroupID: processGroupID
        )
    }

    /// Waits for the captured process generation's real exit event.
    /// DispatchSource closes the registration race without polling; a missing
    /// identity means the process is gone, while a different identity remains
    /// a hard stop so the caller can fail closed before escalation.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func waitForProcessExit(
        pid: pid_t,
        identity: AgentPIDProcessIdentity
    ) async -> Bool {
        guard pid == identity.pid else { return false }
        guard let current = AgentPIDProcessIdentity.includingExitedProcess(pid: pid) else {
            return true
        }
        guard current == identity else { return false }

        let exitEvents = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                continuation.yield(())
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }
        // The process may have exited between the first identity read and
        // source registration; a changed generation is never accepted.
        guard let registeredIdentity = AgentPIDProcessIdentity.includingExitedProcess(pid: pid) else {
            return true
        }
        guard registeredIdentity == identity else { return false }
        for await _ in exitEvents {
            return true
        }
        return AgentPIDProcessIdentity.includingExitedProcess(pid: pid) != identity
    }

    /// Publishes a cancellable deadline event without blocking a cooperative
    /// executor. The process-exit signal races this timer; cancellation tears
    /// down the timer through the stream's termination hook.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func waitForGracePeriod(_ duration: Duration) async -> Bool {
        let components = duration.components
        let seconds = max(0, Double(components.seconds))
        let fractionalSeconds = max(0, Double(components.attoseconds) / 1e18)
        let nanoseconds = min((seconds + fractionalSeconds) * 1e9, Double(Int.max - 1))
        let events = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.setEventHandler {
                continuation.yield(())
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                timer.cancel()
            }
            timer.schedule(
                deadline: .now() + .nanoseconds(Int(nanoseconds.rounded(.up))),
                leeway: .milliseconds(10)
            )
            timer.resume()
        }
        for await _ in events {
            return true
        }
        return false
    }

    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    /// Asynchronously terminates a session using its captured process identity.
    func terminateAsync(
        session: AgentChatOwnedServerSession,
        waitForExit: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard let identity = session.processIdentity,
              let processGroupID = session.processGroupID,
              (1...Int(Int32.max)).contains(session.pid),
              identity.pid == pid_t(session.pid) else {
            return false
        }
        return await terminateAsync(
            identities: [identity],
            processGroupID: processGroupID,
            waitForExit: waitForExit
        )
    }

    /// Used only while a just-spawned child is still suspended and failed the
    /// process-group setup check.  The direct PID signal is allowed here only
    /// after a fresh birth-time comparison; ordinary cleanup always targets a
    /// validated process group through `terminate(identities:processGroupID:)`.
    @discardableResult
    func terminateValidatedProcess(_ identity: AgentPIDProcessIdentity) -> Bool {
        guard identityProvider(identity.pid) == identity else { return false }
        errno = 0
        let result = signalSender(identity.pid, SIGKILL)
        if result == 0 { return true }
        return errno == ESRCH && AgentPIDProcessIdentity.hasExitedWithoutReaping(pid: identity.pid)
    }

    /// Sends one signal after rechecking every captured identity and group.
    private func signalIfValidated(
        identities: [AgentPIDProcessIdentity],
        processGroupID: pid_t,
        signal: Int32,
        identityProvider: @escaping IdentityProvider,
        processGroupProvider: @escaping ProcessGroupProvider,
        processGroupExistsProvider: @escaping ProcessGroupExistsProvider,
        signalSender: @escaping SignalSender
    ) -> Bool {
        // Revalidate the complete launch snapshot immediately before every
        // signal.  Checking only the first matching PID would leave a window
        // where another captured PID was recycled after the outer validation
        // but before this group signal.
        let currentValidation = identities.map {
            validation(
                identity: $0,
                processGroupID: processGroupID,
                identityProvider: identityProvider,
                processGroupProvider: processGroupProvider,
                processGroupExistsProvider: processGroupExistsProvider
            )
        }
        guard !currentValidation.contains(.reused),
              currentValidation.contains(.matching) else {
            return false
        }

        // A negative PID addresses a process group.  The positive PIDs were
        // checked above solely as identity anchors; they are never killed on
        // their own.  A failed kill remains failed cleanup so the caller keeps
        // ownership instead of launching a replacement.
        errno = 0
        let result = signalSender(-processGroupID, signal)
        if result == 0 { return true }
        // The group can disappear between validation and kill.  Treat an
        // ESRCH as clean only after confirming that no replacement group now
        // owns the numeric target; other failures remain a hard stop.
        let failure = errno
        if failure == ESRCH && !processGroupExistsProvider(processGroupID) {
            return true
        }
        if failure == EPERM,
           identities.allSatisfy({ identity in
               AgentPIDProcessIdentity.hasExitedWithoutReaping(pid: identity.pid)
           }) {
            // Darwin reports EPERM when a process group contains only
            // zombies.  All captured generations are already exited, so
            // there is no live signal target left; the caller can reap its
            // child anchor without claiming a kill of an unrelated process.
            return true
        }
        return false
    }

    /// Classifies one captured process generation against current kernel state.
    private func validation(
        identity: AgentPIDProcessIdentity,
        processGroupID: pid_t,
        identityProvider: IdentityProvider? = nil,
        processGroupProvider: ProcessGroupProvider? = nil,
        processGroupExistsProvider: ProcessGroupExistsProvider? = nil
    ) -> IdentityValidation {
        let identityProvider = identityProvider ?? self.identityProvider
        let processGroupProvider = processGroupProvider ?? self.processGroupProvider
        let processGroupExistsProvider = processGroupExistsProvider ?? self.processGroupExistsProvider
        guard let currentIdentity = identityProvider(identity.pid) else { return .gone }
        guard currentIdentity == identity else {
            return .reused
        }
        let isZombie = AgentPIDProcessIdentity.hasExitedWithoutReaping(pid: identity.pid)
        if isZombie {
            // Keep a zombie root as a generation anchor while its group still
            // exists; if the group is gone, cleanup is already complete.
            return processGroupExistsProvider(processGroupID) ? .matching : .gone
        }
        if processGroupProvider(identity.pid) == processGroupID { return .matching }
        // `getpgid` can return ESRCH during the short exit transition even
        // though the process-table birth token is still readable.  If the
        // captured group has also disappeared, there is no signal target left
        // for this launch and it is safe to report the identity as gone.
        if !processGroupExistsProvider(processGroupID) {
            return .gone
        }
        return .reused
    }

}
