import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

extension PortScanner {
    static let processScanTimeout: TimeInterval = 3

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
        lsofScan: PortLsofScanResult?
    ) -> [PanelKey: PortScanCompleteness] {
        let pidsByTTY = pidToTTY.reduce(into: [String: Set<Int>]()) { result, item in
            result[item.value, default: []].insert(item.key)
        }
        return panelTTYs.reduce(into: [:]) { result, item in
            let panelPIDs = pidsByTTY[item.value] ?? []
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
        lsofScan: PortLsofScanResult,
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
        let result = await commandRunner.run(
            directory: "/",
            executable: "/bin/ps",
            arguments: ["-t", ttyList, "-o", "pid=,tty="],
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
            mapping[pid] = String(parts[1])
        }
        let complete = Self.isCompletePSResult(result) && parsedEveryRow
        return (mapping, complete ? .complete : .incomplete)
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

    func runLsof(pidsCsv: String) async -> PortLsofScanResult {
        let result = await commandRunner.run(
            directory: "/",
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", pidsCsv, "-iTCP", "-sTCP:LISTEN", "-Fpn"],
            timeout: Self.processScanTimeout
        )

        var portsByPID: [Int: Set<Int>] = [:]
        var currentPID: Int?
        var parsedEveryRow = true
        var parseIncompletePIDs: Set<Int> = []
        for line in (result.stdout ?? "").split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                guard let pid = Int(line.dropFirst()), pid > 0 else {
                    currentPID = nil
                    parsedEveryRow = false
                    continue
                }
                currentPID = pid
            case "n":
                guard let currentPID else {
                    parsedEveryRow = false
                    continue
                }
                var name = String(line.dropFirst())
                if let arrow = name.range(of: "->") {
                    name = String(name[..<arrow.lowerBound])
                }
                guard let colon = name.lastIndex(of: ":") else {
                    parseIncompletePIDs.insert(currentPID)
                    continue
                }
                let portText = name[name.index(after: colon)...]
                guard portText.allSatisfy(\.isNumber),
                      let port = Int(portText),
                      port > 0,
                      port <= 65_535 else {
                    parseIncompletePIDs.insert(currentPID)
                    continue
                }
                portsByPID[currentPID, default: []].insert(port)
            case "f":
                if line.dropFirst().isEmpty {
                    if let currentPID {
                        parseIncompletePIDs.insert(currentPID)
                    } else {
                        parsedEveryRow = false
                    }
                }
            default:
                if let currentPID {
                    parseIncompletePIDs.insert(currentPID)
                } else {
                    parsedEveryRow = false
                }
            }
        }
        // lsof exits 1 both for "no selected files" and when one requested PID
        // disappears. Keep the failure scoped to the PIDs that can no longer be
        // inspected so unrelated workspaces can still consume complete evidence.
        let requestedPIDs = Set(pidsCsv.split(separator: ",").compactMap { Int($0) })
        var incompletePIDs = parseIncompletePIDs
        incompletePIDs.formUnion(requestedPIDs.filter {
            processIdentityProvider(pid_t($0)) == nil
                && processPresenceProvider(pid_t($0)) != .absent
        })
        let globallyComplete = result.executionError == nil
            && !result.timedOut
            && (result.exitStatus == 0 || result.exitStatus == 1)
            && (result.stderr ?? "").isEmpty
            && parsedEveryRow
        return PortLsofScanResult(
            values: portsByPID,
            globallyComplete: globallyComplete,
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
