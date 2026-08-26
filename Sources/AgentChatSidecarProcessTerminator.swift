import Darwin

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

    private let identityProvider: IdentityProvider
    private let processGroupProvider: ProcessGroupProvider
    private let processGroupExistsProvider: ProcessGroupExistsProvider
    private let signalSender: SignalSender
    private let sleepNanoseconds: (UInt64) -> Void
    private let graceNanoseconds: UInt64 = 400_000_000
    private let pollNanoseconds: UInt64 = 25_000_000

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
        sleepNanoseconds: @escaping (UInt64) -> Void = {
            var request = timespec()
            request.tv_sec = Int($0 / 1_000_000_000)
            request.tv_nsec = Int($0 % 1_000_000_000)
            while true {
                var remaining = timespec()
                let result = Darwin.nanosleep(&request, &remaining)
                if result == 0 || errno != EINTR { return }
                request = remaining
            }
        }
    ) {
        self.identityProvider = identityProvider
        self.processGroupProvider = processGroupProvider
        self.processGroupExistsProvider = processGroupExistsProvider
        self.signalSender = signalSender
        self.sleepNanoseconds = sleepNanoseconds
    }

    /// Returns the only signal target that is safe for the supplied snapshot.
    /// Keeping this decision pure makes the PID-reuse boundary directly
    /// testable without spawning or signaling a real process.
    func validatedGroupTarget(
        identity: AgentPIDProcessIdentity?,
        processGroupID: pid_t?,
        currentIdentity: AgentPIDProcessIdentity?,
        currentProcessGroupID: pid_t?
    ) -> pid_t? {
        guard let identity,
              let processGroupID,
              processGroupID > 1,
              currentIdentity == identity,
              currentProcessGroupID == processGroupID else {
            return nil
        }
        return -processGroupID
    }

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
            // names another generation is not cleanable by this snapshot.
            return initialValidation.allSatisfy { $0 == .gone }
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

        // This is a genuine bounded termination grace period. It stays
        // synchronous so recovery cannot launch a replacement before the
        // identity check and escalation for this generation finish.
        var waited: UInt64 = 0
        while waited < graceNanoseconds {
            let currentValidation = identities.map {
                validation(
                    identity: $0,
                    processGroupID: processGroupID
                )
            }
            if currentValidation.contains(.reused) {
                return false
            }
            if currentValidation.allSatisfy({ $0 == .gone }) {
                return true
            }
            sleepNanoseconds(pollNanoseconds)
            waited += pollNanoseconds
        }

        // Revalidate immediately before escalating.  Never issue SIGKILL from
        // a stale PID/group snapshot after a PID has been recycled.
        let finalValidation = identities.map {
            validation(
                identity: $0,
                processGroupID: processGroupID
            )
        }
        if finalValidation.contains(.reused) {
            return false
        }
        if finalValidation.allSatisfy({ $0 == .gone }) {
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
