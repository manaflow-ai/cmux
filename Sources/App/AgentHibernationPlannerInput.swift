import Darwin
import Foundation

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
