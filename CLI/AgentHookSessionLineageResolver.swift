import CMUXAgentLaunch
import Darwin
import Foundation

/// Resolves an agent hook's run identity and nearest agent-process ancestor.
///
/// The resolver walks at most ``maximumAncestorDepth`` parents and reads only
/// those process records. It never scans the full process table. The resulting
/// lineage is session metadata; restore publication still requires the caller
/// to enforce `restoreAuthority` independently of notification preferences.
struct AgentHookSessionLineageResolver: Sendable {
    private let maximumAncestorDepth = 64

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
        let explicitRunId = Self.normalized(environment["CMUX_CODEX_TEAMS_THREAD_ID"])
        let explicitParentRunId = Self.normalized(environment["CMUX_CODEX_TEAMS_PARENT_THREAD_ID"])

        let identity = pid.flatMap(processIdentity)
        let ancestorResolution = identity.map { agentAncestor(startingAt: $0.parentPID) } ?? .unknown
        let ancestor = ancestorResolution.identity
        let runId = explicitRunId
            ?? identity.map(Self.runId)
            ?? "session:\(agentName):\(sessionId)"
        let parentRunId = explicitParentRunId ?? ancestor.map(Self.runId)
        // Fork metadata is inherited like every other environment variable. It
        // only describes the fork root while that process has no agent ancestor.
        // Descendants must remain children even when they inherit `forked`.
        let isForkRoot = explicitRelationship == .forked
            && !managedChild
            && identity != nil
            && ancestorResolution.provesNoAgentAncestor
        let isSpawnedChild = managedChild
            || ancestor != nil
            || explicitRelationship == .spawned
            || (explicitRelationship == .forked && !isForkRoot)
        let relationship: AgentSessionRelationship? = if isForkRoot {
            .forked
        } else if isSpawnedChild {
            .spawned
        } else {
            explicitRelationship
        }

        return AgentHookSessionLineage(
            runId: runId,
            pid: pid,
            processStartedAt: identity?.startedAt,
            parentRunId: parentRunId,
            parentSessionId: parentSessionId,
            relationship: relationship,
            // A semantic fork on a separate TTY is an independent root. Process
            // ancestry, a managed-child marker, or an explicit spawned marker
            // removes restore authority.
            restoreAuthority: !isSpawnedChild
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

    private func agentAncestor(startingAt parentPID: Int) -> AgentAncestorResolution {
        var candidate = parentPID
        var visited: Set<Int> = []
        var remaining = maximumAncestorDepth
        while candidate > 1, remaining > 0, visited.insert(candidate).inserted {
            guard let identity = processIdentity(candidate) else { return .unknown }
            if AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: identity.executableName,
                arguments: identity.arguments
            ) {
                return .found(identity)
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
        let arguments = processArguments(pid) ?? []
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

    private func processArguments(_ pid: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let success = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        bytes = Array(bytes.prefix(Int(size)))

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { destination in
            destination.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

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
        return arguments.isEmpty ? nil : arguments
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
