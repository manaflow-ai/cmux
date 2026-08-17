import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

extension PortScanner {
    static let processScanTimeout: TimeInterval = 3
    /// Bounds the retry loop that drops terminals `ps` reports as gone, so a
    /// pty churning during a scan cannot spin the scanner.
    static let maximumProcessScanAttempts = 3
    private static let deviceDirectoryPrefix = "/dev/"
    private static let missingDeviceDiagnosticSuffix = ": No such file or directory"

    static func combinedCompleteness(
        _ lhs: PortScanCompleteness,
        _ rhs: PortScanCompleteness
    ) -> PortScanCompleteness {
        lhs == .complete && rhs == .complete ? .complete : .incomplete
    }

    /// Computes panel completeness from the process snapshot and only the PIDs owned by each TTY.
    static func panelCompletenessByKey(
        panelTTYs: [PanelKey: String],
        pidToTTY: [Int: String],
        psCompleteness: PortScanCompleteness,
        lsofScan: PortListenerScanResult?
    ) -> [PanelKey: PortScanCompleteness] {
        let pidsByTTY = pidToTTY.reduce(into: [String: Set<Int>]()) { result, item in
            result[canonicalTTYName(item.value), default: []].insert(item.key)
        }
        return panelTTYs.reduce(into: [:]) { result, item in
            let panelPIDs = pidsByTTY[canonicalTTYName(item.value)] ?? []
            let lsofCompleteness: PortScanCompleteness
            if panelPIDs.isEmpty {
                lsofCompleteness = .complete
            } else if let lsofScan {
                lsofCompleteness = lsofScan.completeness(for: panelPIDs)
            } else {
                lsofCompleteness = .incomplete
            }
            result[item.key] = combinedCompleteness(psCompleteness, lsofCompleteness)
        }
    }

    func expandAgentProcessTree(
        agentRootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]
    ) async -> (
        values: [Int: Set<UUID>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        guard !agentRootsByWorkspace.isEmpty else { return ([:], [:]) }
        let initialRootValidation = validateAgentRoots(agentRootsByWorkspace)
        guard !initialRootValidation.values.isEmpty else {
            return ([:], initialRootValidation.completenessByWorkspace)
        }
        let processScan = await runAllProcesses()
        // A root recycled during `ps` must not inherit descendants from the captured graph.
        let postScanRootValidation = validateAgentRoots(agentRootsByWorkspace)
        var completenessByWorkspace = combineAgentCompleteness(
            initialRootValidation.completenessByWorkspace,
            postScanRootValidation.completenessByWorkspace,
            workspaceIds: Set(agentRootsByWorkspace.keys)
        )
        if processScan.completeness == .incomplete {
            for workspaceId in postScanRootValidation.values.keys {
                completenessByWorkspace[workspaceId] = .incomplete
            }
        }
        return (
            Self.agentProcessOwnership(
                processParents: processScan.values,
                rootsByWorkspace: postScanRootValidation.values
            ),
            completenessByWorkspace
        )
    }

    /// Traverses each captured `(PID, workspace)` pair at most once from already-validated roots.
    static func agentProcessOwnership(
        processParents: [Int: Int],
        rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]
    ) -> [Int: Set<UUID>] {
        var childrenByParent: [Int: [Int]] = [:]
        for (pid, parentPID) in processParents {
            childrenByParent[parentPID, default: []].append(pid)
        }
        var ownershipByPID: [Int: Set<UUID>] = [:]
        var pending: [(pid: Int, workspaceId: UUID)] = []
        for (workspaceId, roots) in rootsByWorkspace {
            for root in roots {
                if ownershipByPID[root.pid, default: []].insert(workspaceId).inserted {
                    pending.append((root.pid, workspaceId))
                }
            }
        }
        var index = 0
        while index < pending.count {
            let (pid, workspaceId) = pending[index]
            index += 1
            for childPID in childrenByParent[pid] ?? [] {
                if ownershipByPID[childPID, default: []].insert(workspaceId).inserted {
                    pending.append((childPID, workspaceId))
                }
            }
        }
        return ownershipByPID
    }

    func validateAgentRoots(
        _ rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]
    ) -> (
        values: [UUID: Set<AgentPortRootIdentity>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        var validRootsByWorkspace: [UUID: Set<AgentPortRootIdentity>] = [:]
        var completenessByWorkspace = rootsByWorkspace.mapValues { _ in PortScanCompleteness.complete }
        for (workspaceId, roots) in rootsByWorkspace {
            for root in roots where root.pid > 0 {
                guard let expectedIdentity = root.processIdentity else {
                    if processPresenceProvider(pid_t(root.pid)) != .absent {
                        completenessByWorkspace[workspaceId] = .incomplete
                    }
                    continue
                }
                guard let currentIdentity = processIdentityProvider(pid_t(root.pid)) else {
                    if processPresenceProvider(pid_t(root.pid)) != .absent {
                        completenessByWorkspace[workspaceId] = .incomplete
                    }
                    continue
                }
                guard currentIdentity == expectedIdentity else { continue }
                validRootsByWorkspace[workspaceId, default: []].insert(root)
            }
        }
        return (validRootsByWorkspace, completenessByWorkspace)
    }

    func captureAgentPIDIdentities(
        ownershipByPID: [Int: Set<UUID>],
        workspaceIds: Set<UUID>
    ) -> (
        ownershipByPID: [Int: Set<UUID>],
        identitiesByPID: [Int: AgentPIDProcessIdentity],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        let capture = capturePIDIdentities(Set(ownershipByPID.keys))
        var retainedOwnership: [Int: Set<UUID>] = [:]
        var completenessByWorkspace = workspaceIds.reduce(into: [UUID: PortScanCompleteness]()) {
            $0[$1] = .complete
        }
        for (pid, workspaceOwnership) in ownershipByPID {
            guard capture.identitiesByPID[pid] != nil else {
                if capture.incompletePIDs.contains(pid) {
                    for workspaceId in workspaceOwnership { completenessByWorkspace[workspaceId] = .incomplete }
                }
                continue
            }
            retainedOwnership[pid] = workspaceOwnership
        }
        return (retainedOwnership, capture.identitiesByPID, completenessByWorkspace)
    }

    func revalidateAgentPIDIdentities(
        ownershipByPID: [Int: Set<UUID>],
        identitiesByPID: [Int: AgentPIDProcessIdentity],
        workspaceIds: Set<UUID>
    ) -> (
        ownershipByPID: [Int: Set<UUID>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        let validation = revalidatePIDIdentities(identitiesByPID)
        var retainedOwnership: [Int: Set<UUID>] = [:]
        var completenessByWorkspace = workspaceIds.reduce(into: [UUID: PortScanCompleteness]()) {
            $0[$1] = .complete
        }
        for (pid, workspaceOwnership) in ownershipByPID {
            guard validation.validPIDs.contains(pid) else {
                if validation.incompletePIDs.contains(pid) {
                    for workspaceId in workspaceOwnership { completenessByWorkspace[workspaceId] = .incomplete }
                }
                continue
            }
            retainedOwnership[pid] = workspaceOwnership
        }
        return (retainedOwnership, completenessByWorkspace)
    }

    func capturePIDIdentities(
        _ pids: Set<Int>
    ) -> (identitiesByPID: [Int: AgentPIDProcessIdentity], incompletePIDs: Set<Int>) {
        var identitiesByPID: [Int: AgentPIDProcessIdentity] = [:]
        var incompletePIDs: Set<Int> = []
        for pid in pids {
            guard let identity = processIdentityProvider(pid_t(pid)), Int(identity.pid) == pid else {
                if processPresenceProvider(pid_t(pid)) != .absent { incompletePIDs.insert(pid) }
                continue
            }
            identitiesByPID[pid] = identity
        }
        return (identitiesByPID, incompletePIDs)
    }

    func revalidatePIDIdentities(
        _ identitiesByPID: [Int: AgentPIDProcessIdentity]
    ) -> (validPIDs: Set<Int>, incompletePIDs: Set<Int>) {
        var validPIDs: Set<Int> = []
        var incompletePIDs: Set<Int> = []
        for (pid, expectedIdentity) in identitiesByPID {
            guard let currentIdentity = processIdentityProvider(pid_t(pid)) else {
                if processPresenceProvider(pid_t(pid)) != .absent { incompletePIDs.insert(pid) }
                continue
            }
            if currentIdentity == expectedIdentity { validPIDs.insert(pid) }
        }
        return (validPIDs, incompletePIDs)
    }

    func revalidatePanelPIDOwnership(
        capturedPIDToTTY: [Int: String],
        capturedIdentitiesByPID: [Int: AgentPIDProcessIdentity],
        refreshedPIDToTTY: [Int: String]
    ) -> (values: [Int: String], incompletePIDs: Set<Int>) {
        let validation = revalidatePIDIdentities(capturedIdentitiesByPID)
        let values = capturedPIDToTTY.reduce(into: [Int: String]()) { result, entry in
            guard validation.validPIDs.contains(entry.key),
                  refreshedPIDToTTY[entry.key] == entry.value else { return }
            result[entry.key] = entry.value
        }
        return (values, validation.incompletePIDs)
    }

    /// Requires captured identities to remain owned in a fresh process graph before accepting PID continuity.
    func finalizeAgentPIDOwnership(
        rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>],
        capturedOwnershipByPID: [Int: Set<UUID>],
        capturedIdentitiesByPID: [Int: AgentPIDProcessIdentity],
        workspaceIds: Set<UUID>
    ) async -> (
        ownershipByPID: [Int: Set<UUID>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        guard !capturedOwnershipByPID.isEmpty else {
            let rootValidation = validateAgentRoots(rootsByWorkspace)
            return (
                [:],
                combineAgentCompleteness(
                    rootValidation.completenessByWorkspace,
                    [:],
                    workspaceIds: workspaceIds
                )
            )
        }
        let currentProcessScan = await runAllProcesses()
        let finalRootValidation = validateAgentRoots(rootsByWorkspace)
        let finalRootOwnership = Self.agentProcessOwnership(
            processParents: currentProcessScan.values,
            rootsByWorkspace: finalRootValidation.values
        )
        let rootFencedOwnership = capturedOwnershipByPID.reduce(into: [Int: Set<UUID>]()) { result, item in
            let retainedWorkspaces = item.value.intersection(finalRootOwnership[item.key] ?? [])
            if !retainedWorkspaces.isEmpty {
                result[item.key] = retainedWorkspaces
            }
        }
        let identityValidation = revalidateAgentPIDIdentities(
            ownershipByPID: rootFencedOwnership,
            identitiesByPID: capturedIdentitiesByPID,
            workspaceIds: workspaceIds
        )
        var completenessByWorkspace = combineAgentCompleteness(
            finalRootValidation.completenessByWorkspace,
            identityValidation.completenessByWorkspace,
            workspaceIds: workspaceIds
        )
        if currentProcessScan.completeness == .incomplete {
            for workspaceId in finalRootValidation.values.keys {
                completenessByWorkspace[workspaceId] = .incomplete
            }
        }
        return (identityValidation.ownershipByPID, completenessByWorkspace)
    }

    func combineAgentCompleteness(
        _ lhs: [UUID: PortScanCompleteness],
        _ rhs: [UUID: PortScanCompleteness],
        workspaceIds: Set<UUID>
    ) -> [UUID: PortScanCompleteness] {
        workspaceIds.reduce(into: [:]) { result, workspaceId in
            result[workspaceId] = Self.combinedCompleteness(
                lhs[workspaceId, default: .complete],
                rhs[workspaceId, default: .complete]
            )
        }
    }

    func agentLsofCompleteness(
        ownershipByPID: [Int: Set<UUID>],
        lsofScan: PortListenerScanResult,
        workspaceIds: Set<UUID>
    ) -> [UUID: PortScanCompleteness] {
        var pidsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ownership) in ownershipByPID {
            for workspaceId in ownership {
                pidsByWorkspace[workspaceId, default: []].insert(pid)
            }
        }
        return workspaceIds.reduce(into: [:]) { result, workspaceId in
            result[workspaceId] = lsofScan.completeness(
                for: pidsByWorkspace[workspaceId] ?? []
            )
        }
    }

    func runPS(ttyList: String) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        var remaining = Self.orderedTTYNames(in: ttyList)
        guard !remaining.isEmpty else { return ([:], .complete) }

        for attempt in 0..<Self.maximumProcessScanAttempts {
            let result = await commandRunner.run(
                directory: "/",
                executable: "/bin/ps",
                arguments: ["-t", remaining.joined(separator: ","), "-o", "pid=,tty="],
                timeout: Self.processScanTimeout
            )

            var mapping: [Int: String] = [:]
            var parsedEveryRow = true
            for line in (result.stdout ?? "").split(separator: "\n") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 2, let pid = Int(parts[0]), pid > 0 else {
                    parsedEveryRow = false
                    continue
                }
                mapping[pid] = Self.canonicalTTYName(String(parts[1]))
            }
            if Self.isCompletePSResult(result) && parsedEveryRow {
                return (mapping, .complete)
            }

            let vanished = Self.vanishedTTYNames(
                inStderr: result.stderr,
                requested: Set(remaining)
            )
            guard !vanished.isEmpty else { return (mapping, .incomplete) }
            remaining.removeAll { vanished.contains($0) }
            // Every terminal is gone, which is authoritative emptiness rather
            // than a failed scan: no process can be attached to a freed pty.
            // Emptiness outranks the retry budget so the verdict does not
            // depend on which attempt the last pty happened to close during.
            guard !remaining.isEmpty else { return ([:], .complete) }
            guard attempt < Self.maximumProcessScanAttempts - 1 else {
                return (mapping, .incomplete)
            }
        }
        return ([:], .incomplete)
    }

    private static func orderedTTYNames(in ttyList: String) -> [String] {
        var seen: Set<String> = []
        return ttyList.split(separator: ",").compactMap { field in
            let name = String(field)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// Terminals that `ps` reported as no longer present on the filesystem.
    ///
    /// BSD `ps` abandons the whole `-t` query when any listed device is gone,
    /// naming each one on stderr and writing nothing to stdout. Retrying
    /// without them keeps one closed pty from erasing every other panel's
    /// evidence. Only ENOENT is treated as absence; any other diagnostic
    /// leaves the scan incomplete so ports are retained rather than dropped.
    ///
    /// Matching the English `strerror(ENOENT)` suffix is safe regardless of the
    /// user's locale: Darwin libc ships no localized message catalogs, so
    /// `ps` emits this exact text even under a non-English `LC_ALL`.
    static func vanishedTTYNames(inStderr stderr: String?, requested: Set<String>) -> Set<String> {
        guard let stderr, !stderr.isEmpty else { return [] }
        // Direct callers can supply either `ttys1` or `/dev/ttys1`; match on
        // the canonical device name either form names.
        let requestedByDeviceName = requested.reduce(into: [String: Set<String>]()) { result, name in
            result[Self.canonicalTTYName(name), default: []].insert(name)
        }
        var vanished: Set<String> = []
        for line in stderr.split(separator: "\n") {
            guard line.hasSuffix(Self.missingDeviceDiagnosticSuffix) else { continue }
            let paths = String(line.dropLast(Self.missingDeviceDiagnosticSuffix.count))
            // For a name that does not already start with `tty`, `ps` stats
            // both candidate devices and names them in one diagnostic:
            // "ps: /dev/ttyfoo and /dev/foo: No such file or directory".
            for path in paths.components(separatedBy: " and ") {
                guard let devicePrefix = path.range(of: Self.deviceDirectoryPrefix) else { continue }
                let deviceName = String(path[devicePrefix.upperBound...])
                if let names = requestedByDeviceName[deviceName] {
                    vanished.formUnion(names)
                }
            }
        }
        return vanished
    }

    /// Canonicalizes the shell's full device path and `ps`'s abbreviated TTY
    /// field to one identity used by every scan join.
    static func canonicalTTYName(_ ttyName: String) -> String {
        guard ttyName.hasPrefix(Self.deviceDirectoryPrefix) else { return ttyName }
        return String(ttyName.dropFirst(Self.deviceDirectoryPrefix.count))
    }

    func runAllProcesses() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        let result = await commandRunner.run(
            directory: "/",
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,ppid="],
            timeout: Self.processScanTimeout
        )

        var mapping: [Int: Int] = [:]
        var parsedEveryRow = true
        for line in (result.stdout ?? "").split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  let pid = Int(parts[0]),
                  let parentPid = Int(parts[1]),
                  pid > 0,
                  parentPid >= 0 else {
                parsedEveryRow = false
                continue
            }
            mapping[pid] = parentPid
        }
        let complete = Self.isComplete(result) && parsedEveryRow
        return (mapping, complete ? .complete : .incomplete)
    }

    /// Reads listening TCP ports for each requested PID directly from the
    /// kernel. Every PID answers for itself, so one unreadable process no
    /// longer costs the whole scan its evidence.
    ///
    /// The callers are async, so this blocks a cooperative thread. That is safe
    /// at the current scale: the libproc calls measure about 1.25us per process,
    /// so a scan holds one thread for well under a millisecond every couple of
    /// seconds, and scans never overlap. Give it its own queue if that stops
    /// being true — if scans start running concurrently, or if a process with a
    /// very large descriptor table makes one scan slow, since the cost is per
    /// descriptor rather than per PID.
    func scanListeningPorts(pidsCsv: String) -> PortListenerScanResult {
        let requestedPIDs = Set(pidsCsv.split(separator: ",").compactMap { Int($0) })
        var portsByPID: [Int: Set<Int>] = [:]
        var incompletePIDs: Set<Int> = []

        for pid in requestedPIDs {
            switch listeningPortsProvider(pid_t(pid)) {
            case .ports(let ports):
                if !ports.isEmpty {
                    portsByPID[pid] = ports
                }
            case .denied, .unavailable:
                // An unprivileged caller cannot read a root-owned process's
                // sockets, and neither could lsof. Only a PID whose identity is
                // unreadable while it is still present counts as a miss, so a
                // panel behind the root `login` process can still retire ports.
                if processIdentityProvider(pid_t(pid)) == nil
                    && processPresenceProvider(pid_t(pid)) != .absent {
                    incompletePIDs.insert(pid)
                }
            }
        }

        return PortListenerScanResult(
            values: portsByPID,
            globallyComplete: true,
            incompletePIDs: incompletePIDs
        )
    }

    private static func isComplete(_ result: CommandResult) -> Bool {
        result.executionError == nil
            && !result.timedOut
            && result.exitStatus == 0
            && (result.stderr ?? "").isEmpty
    }

    private static func isCompletePSResult(_ result: CommandResult) -> Bool {
        // BSD ps exits 1 when a valid selector matches no processes.
        return isComplete(result)
            || (result.executionError == nil
                && !result.timedOut
                && result.exitStatus == 1
                && (result.stdout ?? "").isEmpty
                && (result.stderr ?? "").isEmpty)
    }
}
