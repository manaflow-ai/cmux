import Darwin
import Foundation
import os

private func agentHibernationKevent(
    _ queue: Int32,
    _ changes: UnsafePointer<kevent>?,
    _ changeCount: Int32,
    _ events: UnsafeMutablePointer<kevent>?,
    _ eventCount: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32 {
    let systemKevent: (
        Int32,
        UnsafePointer<kevent>?,
        Int32,
        UnsafeMutablePointer<kevent>?,
        Int32,
        UnsafePointer<timespec>?
    ) -> Int32 = kevent
    return systemKevent(queue, changes, changeCount, events, eventCount, timeout)
}

struct AgentHibernationProcessGenerationFence: @unchecked Sendable {
    enum State: Equatable {
        case originalGenerationAlive
        case originalGenerationExited
        case unavailable
    }

    private final class KernelFence: @unchecked Sendable {
        private enum Storage {
            case active
            case exited
            case unavailable
        }

        private let descriptor: Int32
        private let processID: pid_t
        private let storage = OSAllocatedUnfairLock(initialState: Storage.active)

        init?(processID: pid_t) {
            let descriptor = kqueue()
            guard descriptor >= 0 else { return nil }
            var event = kevent(
                ident: UInt(processID),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil
            )
            guard agentHibernationKevent(descriptor, &event, 1, nil, 0, nil) == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            self.descriptor = descriptor
            self.processID = processID
        }

        deinit {
            Darwin.close(descriptor)
        }

        func currentState() -> State {
            storage.withLock { storage in
                switch storage {
                case .exited:
                    return .originalGenerationExited
                case .unavailable:
                    return .unavailable
                case .active:
                    break
                }
                var event = kevent()
                var timeout = timespec(tv_sec: 0, tv_nsec: 0)
                while true {
                    let result = agentHibernationKevent(
                        descriptor,
                        nil,
                        0,
                        &event,
                        1,
                        &timeout
                    )
                    if result == 0 {
                        return .originalGenerationAlive
                    }
                    if result == 1,
                       event.filter == Int16(EVFILT_PROC),
                       event.ident == UInt(processID),
                       event.fflags & UInt32(NOTE_EXIT) != 0 {
                        storage = .exited
                        return .originalGenerationExited
                    }
                    if result < 0, errno == EINTR {
                        continue
                    }
                    storage = .unavailable
                    return .unavailable
                }
            }
        }
    }

    private let stateProvider: @Sendable () -> State

    init?(processID: pid_t) {
        guard let fence = KernelFence(processID: processID) else { return nil }
        stateProvider = { fence.currentState() }
    }

    init(stateProvider: @escaping @Sendable () -> State) {
        self.stateProvider = stateProvider
    }

    func currentState() -> State {
        stateProvider()
    }
}

final class AgentHibernationFrozenShellLease: @unchecked Sendable {
    private enum State {
        case active
        case resumed
        case ownerGoneOrReplaced
    }

    let processFreeLease: AgentHibernationProcessFreeLease
    private let state = OSAllocatedUnfairLock(initialState: State.active)
    private let generationFence: AgentHibernationProcessGenerationFence
    private let processIdentity: @Sendable (Int) -> AgentPIDProcessIdentity?
    private let processStatus: @Sendable (Int) -> UInt32?
    private let sendSignal: @Sendable (pid_t, Int32) -> Int32

    fileprivate init(
        processFreeLease: AgentHibernationProcessFreeLease,
        generationFence: AgentHibernationProcessGenerationFence,
        processIdentity: @escaping @Sendable (Int) -> AgentPIDProcessIdentity?,
        processStatus: @escaping @Sendable (Int) -> UInt32?,
        sendSignal: @escaping @Sendable (pid_t, Int32) -> Int32
    ) {
        self.processFreeLease = processFreeLease
        self.generationFence = generationFence
        self.processIdentity = processIdentity
        self.processStatus = processStatus
        self.sendSignal = sendSignal
    }

    var guardedProcessIDs: Set<Int> { [processFreeLease.shellPID] }

    func isStillFrozenAndProcessFree(
        finalProcessFreeValidation: (@Sendable () -> Bool)? = nil
    ) -> Bool {
        guard state.withLock({ $0 == .active }),
              processIdentity(processFreeLease.shellPID) == processFreeLease.shellIdentity,
              generationFence.currentState() == .originalGenerationAlive,
              processStatus(processFreeLease.shellPID) == UInt32(SSTOP) else {
            return false
        }
        return finalProcessFreeValidation?() ?? processFreeLease.isStillProcessFree()
    }

    func resume() {
        state.withLock { state in
            guard state == .active else { return }
            let currentIdentity = processIdentity(processFreeLease.shellPID)
            if let currentIdentity,
               currentIdentity != processFreeLease.shellIdentity {
                state = .ownerGoneOrReplaced
                return
            }
            if currentIdentity == nil {
                switch generationFence.currentState() {
                case .originalGenerationExited:
                    state = .ownerGoneOrReplaced
                    return
                case .unavailable:
                    os_log(.fault, "Unable to prove frozen shell generation before SIGCONT")
                    return
                case .originalGenerationAlive:
                    break
                }
            }

            errno = 0
            guard sendSignal(processFreeLease.shellIdentity.pid, SIGCONT) == 0 else {
                let signalError = errno
                if signalError == ESRCH {
                    state = .ownerGoneOrReplaced
                } else {
                    os_log(
                        .fault,
                        "SIGCONT failed for proven frozen shell generation: errno=%{public}d",
                        signalError
                    )
                }
                return
            }
            state = .resumed
        }
    }

    deinit {
        resume()
    }
}

struct AgentHibernationProcessFreeLease: Sendable, Equatable {
    struct ProcessTopology: Sendable, Equatable {
        let parentPID: Int
        let name: String
        let ttyDevice: Int64?
        let processGroupID: Int?
        let terminalProcessGroupID: Int?
    }

    let workspaceId: UUID
    let panelId: UUID
    let shellPID: Int
    let shellIdentity: AgentPIDProcessIdentity
    let shellParentPID: Int
    let shellName: String
    let executablePath: String
    let arguments: [String]
    let ttyDevice: Int64
    let sessionID: Int
    let processGroupID: Int
    let terminalProcessGroupID: Int

    var guardedProcessIDs: Set<Int> { [shellPID] }

    func freezeForFinalTeardown(
        processIdentity: @escaping @Sendable (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        processStatus: @escaping @Sendable (Int) -> UInt32? = {
            Self.currentProcessStatus(pid: $0)
        },
        processGenerationFence: @escaping @Sendable (pid_t) -> AgentHibernationProcessGenerationFence? = {
            AgentHibernationProcessGenerationFence(processID: $0)
        },
        sendSignal: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        waitForStoppedChild: @escaping @Sendable (pid_t) -> Bool = { pid in
            Self.waitForStoppedDirectChild(pid: pid)
        },
        finalProcessFreeValidation: (@Sendable () -> Bool)? = nil
    ) -> AgentHibernationFrozenShellLease? {
        // Never resume a shell that the user or debugger had already stopped.
        guard processIdentity(shellPID) == shellIdentity,
              let initialStatus = processStatus(shellPID),
              initialStatus != UInt32(SSTOP),
              let generationFence = processGenerationFence(shellIdentity.pid),
              processIdentity(shellPID) == shellIdentity,
              generationFence.currentState() == .originalGenerationAlive,
              sendSignal(shellIdentity.pid, SIGSTOP) == 0 else {
            return nil
        }
        let frozenLease = AgentHibernationFrozenShellLease(
            processFreeLease: self,
            generationFence: generationFence,
            processIdentity: processIdentity,
            processStatus: processStatus,
            sendSignal: sendSignal
        )
        guard waitForStoppedChild(shellIdentity.pid),
              frozenLease.isStillFrozenAndProcessFree(
                finalProcessFreeValidation: finalProcessFreeValidation
              ) else {
            frozenLease.resume()
            return nil
        }
        return frozenLease
    }

    private static func waitForStoppedDirectChild(pid: pid_t) -> Bool {
        var information = siginfo_t()
        while true {
            let result = waitid(
                P_PID,
                id_t(pid),
                &information,
                WSTOPPED | WEXITED | WNOWAIT
            )
            if result == 0 {
                return information.si_pid == pid
                    && information.si_code == CLD_STOPPED
                    && information.si_status == SIGSTOP
            }
            if errno != EINTR { return false }
        }
    }

    func isStillProcessFree(
        processArguments: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processIdentity: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        processExecutablePath: (Int) -> String? = {
            CmuxTopProcessSnapshot.processExecutablePath(for: $0)
        },
        processSessionID: (Int) -> pid_t? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            let value = getsid(pid_t($0))
            return value > 0 ? value : nil
        },
        ttyProcessIDs: (Int64) -> CmuxTopTargetedPIDEnumeration = {
            CmuxTopProcessSnapshot.processIDs(forTTYDevice: $0)
        },
        childProcessIDs: (Int) -> CmuxTopTargetedPIDEnumeration = {
            CmuxTopProcessSnapshot.childProcessIDs(of: $0)
        },
        processTopology: (Int) -> ProcessTopology? = {
            Self.currentTopology(pid: $0)
        }
    ) -> Bool {
        guard processIdentity(shellPID) == shellIdentity,
              let topology = processTopology(shellPID),
              topology.parentPID == shellParentPID,
              topology.name == shellName,
              topology.ttyDevice == ttyDevice,
              topology.processGroupID == processGroupID,
              topology.terminalProcessGroupID == terminalProcessGroupID,
              processSessionID(shellPID) == pid_t(sessionID),
              processExecutablePath(shellPID) == executablePath,
              let currentArguments = processArguments(shellPID),
              currentArguments.arguments == arguments,
              currentArguments.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId),
              case .complete(let ttyPIDs) = ttyProcessIDs(ttyDevice),
              ttyPIDs == [shellPID],
              case .complete(let childPIDs) = childProcessIDs(shellPID),
              childPIDs.isEmpty,
              processIdentity(shellPID) == shellIdentity else {
            return false
        }
        return true
    }

    private static func currentTopology(
        pid: Int
    ) -> ProcessTopology? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { rawBuffer in
            let end = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tty = Int64(info.e_tdev)
        let processGroupID = Int(info.pbi_pgid)
        let terminalProcessGroupID = Int(info.e_tpgid)
        return ProcessTopology(
            parentPID: Int(info.pbi_ppid),
            name: name,
            ttyDevice: tty > 0 ? tty : nil,
            processGroupID: processGroupID > 0 ? processGroupID : nil,
            terminalProcessGroupID: terminalProcessGroupID > 0 ? terminalProcessGroupID : nil
        )
    }

    private static func currentProcessStatus(pid: Int) -> UInt32? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return info.pbi_status
    }
}

enum AgentHibernationProcessEvidence: Sendable, Equatable {
    case confirmedProcessFree(AgentHibernationProcessFreeLease)
    case unverified(processIDs: Set<Int>)

    var allowsHibernation: Bool {
        if case .confirmedProcessFree = self { return true }
        return false
    }

    var processIDs: Set<Int> {
        switch self {
        case .confirmedProcessFree:
            return []
        case .unverified(let processIDs):
            return processIDs
        }
    }

    var lease: AgentHibernationProcessFreeLease? {
        guard case .confirmedProcessFree(let lease) = self else { return nil }
        return lease
    }
}

struct AgentHibernationProcessTopologyIndex {
    private let evidenceByPanel: [RestorableAgentSessionIndex.PanelKey: AgentHibernationProcessEvidence]

    var allEvidence: [RestorableAgentSessionIndex.PanelKey: AgentHibernationProcessEvidence] {
        evidenceByPanel
    }

    init(
        processSnapshot: CmuxTopProcessSnapshot,
        targetPanelKeys: Set<RestorableAgentSessionIndex.PanelKey>,
        targetPanelIDs: Set<UUID> = [],
        processArguments: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processIdentity: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        processExecutablePath: (Int) -> String? = {
            CmuxTopProcessSnapshot.processExecutablePath(for: $0)
        },
        processSessionID: (Int) -> pid_t? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            let value = getsid(pid_t($0))
            return value > 0 ? value : nil
        },
        ttyProcessIDs: (Int64) -> CmuxTopTargetedPIDEnumeration = {
            CmuxTopProcessSnapshot.processIDs(forTTYDevice: $0)
        },
        childProcessIDs: (Int) -> CmuxTopTargetedPIDEnumeration = {
            CmuxTopProcessSnapshot.childProcessIDs(of: $0)
        }
    ) {
        var scopedByPanel: [RestorableAgentSessionIndex.PanelKey: [CmuxTopProcessInfo]] = [:]
        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID else {
                continue
            }
            let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard targetPanelKeys.contains(key) || targetPanelIDs.contains(panelId) else { continue }
            scopedByPanel[key, default: []].append(process)
        }

        var ttyEnumerationCache: [Int64: CmuxTopTargetedPIDEnumeration] = [:]
        var evidence: [RestorableAgentSessionIndex.PanelKey: AgentHibernationProcessEvidence] = [:]
        let effectiveTargetKeys = targetPanelKeys.union(scopedByPanel.keys)
        evidence.reserveCapacity(effectiveTargetKeys.count)
        for key in effectiveTargetKeys {
            let scoped = scopedByPanel[key] ?? []
            let observedPIDs = Set(scoped.map(\.pid))
            guard scoped.count == 1,
                  let shell = scoped.first,
                  Self.isTerminalShell(shell),
                  let ttyDevice = shell.ttyDevice,
                  let processGroupID = shell.processGroupID,
                  let terminalProcessGroupID = shell.terminalProcessGroupID,
                  processGroupID == terminalProcessGroupID,
                  let shellIdentity = shell.generationIdentity,
                  processIdentity(shell.pid) == shellIdentity,
                  let executablePath = processExecutablePath(shell.pid),
                  let sessionID = processSessionID(shell.pid),
                  let arguments = processArguments(shell.pid),
                  arguments.matchesCMUXScope(workspaceId: key.workspaceId, surfaceId: key.panelId),
                  processIdentity(shell.pid) == shellIdentity else {
                evidence[key] = .unverified(processIDs: observedPIDs)
                continue
            }

            let ttyEnumeration: CmuxTopTargetedPIDEnumeration
            if let cached = ttyEnumerationCache[ttyDevice] {
                ttyEnumeration = cached
            } else {
                ttyEnumeration = ttyProcessIDs(ttyDevice)
                ttyEnumerationCache[ttyDevice] = ttyEnumeration
            }
            guard case .complete(let ttyPIDs) = ttyEnumeration,
                  ttyPIDs == [shell.pid],
                  case .complete(let children) = childProcessIDs(shell.pid),
                  children.isEmpty else {
                let extraPIDs: Set<Int>
                if case .complete(let ttyPIDs) = ttyEnumeration {
                    extraPIDs = observedPIDs.union(ttyPIDs)
                } else {
                    extraPIDs = observedPIDs
                }
                evidence[key] = .unverified(processIDs: extraPIDs)
                continue
            }

            evidence[key] = .confirmedProcessFree(AgentHibernationProcessFreeLease(
                workspaceId: key.workspaceId,
                panelId: key.panelId,
                shellPID: shell.pid,
                shellIdentity: shellIdentity,
                shellParentPID: shell.parentPID,
                shellName: shell.name,
                executablePath: executablePath,
                arguments: arguments.arguments,
                ttyDevice: ttyDevice,
                sessionID: Int(sessionID),
                processGroupID: processGroupID,
                terminalProcessGroupID: terminalProcessGroupID
            ))
        }
        evidenceByPanel = evidence
    }

    func evidence(for key: RestorableAgentSessionIndex.PanelKey) -> AgentHibernationProcessEvidence {
        evidenceByPanel[key] ?? .unverified(processIDs: [])
    }

    private static func isTerminalShell(_ process: CmuxTopProcessInfo) -> Bool {
        let name = process.name.lowercased()
        let basename = ((process.path ?? process.name) as NSString).lastPathComponent.lowercased()
        let shells: Set<String> = [
            "bash", "csh", "dash", "elvish", "fish", "ksh", "nu", "sh", "tcsh", "xonsh", "zsh",
        ]
        return shells.contains(name) || shells.contains(basename)
    }
}

struct AgentHibernationPlannerInput: Sendable {
    let key: AgentHibernationPanelKey
    let hasRestorableAgent: Bool
    let isLive: Bool
    let processEvidence: AgentHibernationProcessEvidence
    let isProtected: Bool
    let lifecycle: AgentHibernationLifecycleState
    let isTemporarilyUnableToProtect: Bool
    let hasUnconfirmedTerminalInput: Bool
    let lastActivityAt: TimeInterval

    init(
        key: AgentHibernationPanelKey,
        hasRestorableAgent: Bool,
        isLive: Bool,
        processEvidence: AgentHibernationProcessEvidence = .unverified(processIDs: []),
        isProtected: Bool,
        lifecycle: AgentHibernationLifecycleState,
        isTemporarilyUnableToProtect: Bool = false,
        hasUnconfirmedTerminalInput: Bool,
        lastActivityAt: TimeInterval
    ) {
        self.key = key
        self.hasRestorableAgent = hasRestorableAgent
        self.isLive = isLive
        self.processEvidence = processEvidence
        self.isProtected = isProtected
        self.lifecycle = lifecycle
        self.isTemporarilyUnableToProtect = isTemporarilyUnableToProtect
        self.hasUnconfirmedTerminalInput = hasUnconfirmedTerminalInput
        self.lastActivityAt = lastActivityAt
    }
}
