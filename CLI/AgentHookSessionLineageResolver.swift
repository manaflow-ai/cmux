import CMUXAgentLaunch
import Darwin
import Foundation

struct AgentHookSessionAuthority: Sendable, Equatable {
    var relationship: AgentSessionRelationship?
    var restoreAuthority: Bool
    var evidence: AgentSessionAuthorityEvidence?
}

/// Classifies restore ownership from explicit markers and bounded ancestry.
/// Missing PID metadata retains legacy root behavior, while a failed ancestry
/// walk after resolving the process itself fails closed as a child.
struct AgentHookSessionAuthorityPolicy: Sendable {
    func classify(
        managedChild: Bool,
        explicitRelationship: AgentSessionRelationship?,
        processIdentityAvailable: Bool,
        hasAgentAncestor: Bool,
        ancestryProvenAbsent: Bool
    ) -> AgentHookSessionAuthority {
        let isForkRoot = explicitRelationship == .forked
            && !managedChild
            && processIdentityAvailable
            && !hasAgentAncestor
            && ancestryProvenAbsent
        let ancestryAmbiguous = processIdentityAvailable
            && !hasAgentAncestor
            && !ancestryProvenAbsent
        let isSpawnedChild = managedChild
            || hasAgentAncestor
            || ancestryAmbiguous
            || explicitRelationship == .spawned
            || (explicitRelationship == .forked && !isForkRoot)
        let relationship: AgentSessionRelationship? = if isForkRoot {
            .forked
        } else if isSpawnedChild {
            .spawned
        } else {
            explicitRelationship
        }
        let evidence: AgentSessionAuthorityEvidence? = if isForkRoot {
            .verifiedForkRoot
        } else if managedChild {
            .managedChild
        } else if explicitRelationship == .spawned {
            .explicitSpawnedChild
        } else if hasAgentAncestor {
            .verifiedAncestorChild
        } else if isSpawnedChild {
            .provisionalAmbiguousChild
        } else {
            nil
        }
        return AgentHookSessionAuthority(
            relationship: relationship,
            restoreAuthority: !isSpawnedChild,
            evidence: evidence
        )
    }
}

/// Resolves an agent hook's run identity and nearest agent-process ancestor.
///
/// The resolver walks at most ``maximumAncestorDepth`` parents and reads only
/// those process records. It never scans the full process table. The resulting
/// lineage is session metadata; restore publication still requires the caller
/// to enforce `restoreAuthority` independently of notification preferences.
struct AgentHookSessionLineageResolver: Sendable {
    private let maximumAncestorDepth = 64
    private let launchModeClassifier: AgentLaunchModeClassifier

    init(launchModeClassifier: AgentLaunchModeClassifier = AgentLaunchModeClassifier()) {
        self.launchModeClassifier = launchModeClassifier
    }

    func resolve(
        agentName: String,
        sessionId: String,
        pid: Int?,
        environment: [String: String]
    ) -> AgentHookSessionLineage {
        let managedChild = Self.bool(environment["CMUX_AGENT_MANAGED_SUBAGENT"]) == true
        let explicitRelationship = environment["CMUX_AGENT_RELATIONSHIP"]
            .flatMap(Self.relationship)
        let parentSessionId = Self.normalized(environment["CMUX_AGENT_PARENT_SESSION_ID"])
        let isCodex = Self.normalized(agentName)?.lowercased() == "codex"
        let explicitRunId = isCodex ? Self.normalized(environment["CMUX_CODEX_TEAMS_THREAD_ID"]) : nil
        let explicitParentRunId = isCodex
            ? Self.normalized(environment["CMUX_CODEX_TEAMS_PARENT_THREAD_ID"])
            : nil

        let identity = pid.flatMap(processIdentity)
        let processDescribesAgent = identity.map {
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: $0.executableName,
                arguments: $0.arguments,
                kind: agentName
            )
        } ?? false
        let processLaunchMode = identity.map {
            launchModeClassifier.processMode(
                processName: $0.executableName,
                arguments: $0.arguments,
                kind: agentName
            )
        } ?? .unknown
        let hibernationResumeAttemptId = Self.normalized(
            environment[AgentHibernationResumeEvidence.environmentKey]
        ).flatMap { UUID(uuidString: $0) }
        let cmuxRuntime = AgentCmuxRuntimeIdentity(environment: environment)
        let ancestorResolution = identity.map {
            agentAncestor(startingAt: $0.parentPID, descendant: $0, agentName: agentName)
        } ?? .unknown
        let ancestor = ancestorResolution.identity
        let runId = explicitRunId
            ?? identity.map(Self.runId)
            ?? cmuxRuntime.map { "runtime:\($0.id):session:\(agentName):\(sessionId)" }
            ?? "session:\(agentName):\(sessionId)"
        let parentRunId = explicitParentRunId ?? ancestor.map(Self.runId)
        let authority = AgentHookSessionAuthorityPolicy().classify(
            managedChild: managedChild,
            explicitRelationship: explicitRelationship,
            processIdentityAvailable: identity != nil,
            hasAgentAncestor: ancestor != nil,
            ancestryProvenAbsent: ancestorResolution.provesNoAgentAncestor
        )

        return AgentHookSessionLineage(
            runId: runId,
            pid: pid,
            processStartedAt: identity?.startedAt,
            processDescribesAgent: processDescribesAgent,
            processLaunchMode: processLaunchMode,
            hibernationResumeAttemptId: hibernationResumeAttemptId,
            cmuxRuntime: cmuxRuntime,
            parentRunId: parentRunId,
            parentSessionId: parentSessionId,
            relationship: authority.relationship,
            restoreAuthority: authority.restoreAuthority,
            authorityEvidence: authority.evidence
        )
    }

    func processState(pid: Int?, expectedStartedAt: TimeInterval?) -> AgentProcessState {
        guard let pid, let expectedStartedAt else { return .unknown }
        guard let process = kernelProcessInfo(pid) else { return .exited }
        let start = process.kp_proc.p_un.__p_starttime
        let actualStartedAt = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        return abs(actualStartedAt - expectedStartedAt) <= 0.001 ? .alive : .exited
    }

    private enum AgentAncestorResolution {
        case found(AgentProcessIdentity)
        case none
        case unknown

        var identity: AgentProcessIdentity? {
            guard case let .found(identity) = self else { return nil }
            return identity
        }

        var provesNoAgentAncestor: Bool {
            if case .none = self { return true }
            return false
        }
    }

    private func agentAncestor(
        startingAt parentPID: Int,
        descendant initialDescendant: AgentProcessIdentity,
        agentName: String
    ) -> AgentAncestorResolution {
        var candidate = parentPID
        var descendant = initialDescendant
        var visited: Set<Int> = []
        var remaining = maximumAncestorDepth
        while candidate > 1, remaining > 0, visited.insert(candidate).inserted {
            guard let identity = processIdentity(candidate) else { return .unknown }
            if identity.isCmuxTerminalHost {
                return .none
            }
            if AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: identity.executableName,
                arguments: identity.arguments,
                kind: agentName
            ) || AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: identity.executableName,
                arguments: identity.arguments
            ) {
                if identity.pid == descendant.parentPID,
                   AgentLaunchCaptureTrust.nativeProcessIsSameAgentLauncherRelay(
                    parentProcessName: identity.executableName,
                    parentArguments: identity.arguments,
                    childProcessName: descendant.executableName,
                    childArguments: descendant.arguments,
                    kind: agentName
                ) {
                    descendant = identity
                    candidate = identity.parentPID
                    remaining -= 1
                    continue
                }
                return .found(identity)
            }
            if AgentLaunchCaptureTrust.nativeProcessIsAmbiguousInterpreterHost(
                processName: identity.executableName,
                arguments: identity.arguments
            ) {
                return .unknown
            }
            candidate = identity.parentPID
            remaining -= 1
        }
        return candidate <= 1 ? .none : .unknown
    }

    private func processIdentity(_ pid: Int) -> AgentProcessIdentity? {
        guard let process = kernelProcessInfo(pid) else { return nil }
        let start = process.kp_proc.p_un.__p_starttime
        let startedAt = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        let arguments = processArguments(pid)
        return AgentProcessIdentity(
            pid: pid,
            parentPID: Int(process.kp_eproc.e_ppid),
            startedAt: startedAt,
            executableName: executableName(pid, arguments: arguments),
            arguments: arguments
        )
    }

    private func kernelProcessInfo(_ pid: Int) -> kinfo_proc? {
        guard pid > 1, pid <= Int(Int32.max) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &process, &length, nil, 0) == 0,
              length >= MemoryLayout<kinfo_proc>.stride,
              process.kp_proc.p_pid == pid_t(pid) else {
            return nil
        }
        return process
    }

    private func executableName(_ pid: Int, arguments: [String]) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid_t(pid), pointer.baseAddress, UInt32(pointer.count))
        }
        if length > 0 {
            return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        }
        return arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private func processArguments(_ pid: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return []
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let success = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return [] }
        bytes = Array(bytes.prefix(Int(size)))

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { destination in
            destination.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        Self.skipString(bytes, index: &index)
        Self.skipNulls(bytes, index: &index)
        var arguments: [String] = []
        for _ in 0..<argc where index < bytes.count {
            let start = index
            Self.skipString(bytes, index: &index)
            if let argument = String(bytes: bytes[start..<index], encoding: .utf8) {
                arguments.append(argument)
            }
            if index < bytes.count { index += 1 }
        }
        return arguments
    }

    private static func skipString(_ bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 { index += 1 }
    }

    private static func skipNulls(_ bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 { index += 1 }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func bool(_ value: String?) -> Bool? {
        switch normalized(value)?.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }

    private static func relationship(_ value: String) -> AgentSessionRelationship? {
        AgentSessionRelationship(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func runId(_ identity: AgentProcessIdentity) -> String {
        "pid:\(identity.pid)@\(Int64(identity.startedAt * 1_000_000))"
    }
}
