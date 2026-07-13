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
        values: [Int: [UUID: Set<AgentPortRootIdentity>]],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        let rootValidation = validateAgentRoots(agentRootsByWorkspace)
        guard !rootValidation.values.isEmpty else {
            return ([:], rootValidation.completenessByWorkspace)
        }

        var ownershipByPID: [Int: [UUID: Set<AgentPortRootIdentity>]] = [:]
        var pending: [(pid: Int, workspaceId: UUID, root: AgentPortRootIdentity)] = []
        for (workspaceId, roots) in rootValidation.values {
            for root in roots {
                var ownership = ownershipByPID[root.pid] ?? [:]
                var ownedRoots = ownership[workspaceId] ?? []
                if ownedRoots.insert(root).inserted {
                    ownership[workspaceId] = ownedRoots
                    ownershipByPID[root.pid] = ownership
                    pending.append((root.pid, workspaceId, root))
                }
            }
        }

        let processScan = await runAllProcesses()
        var childrenByParent: [Int: [Int]] = [:]
        for (pid, parentPid) in processScan.values {
            childrenByParent[parentPid, default: []].append(pid)
        }

        var index = 0
        while index < pending.count {
            let (pid, workspaceId, root) = pending[index]
            index += 1
            for childPID in childrenByParent[pid] ?? [] {
                var ownership = ownershipByPID[childPID] ?? [:]
                var ownedRoots = ownership[workspaceId] ?? []
                if ownedRoots.insert(root).inserted {
                    ownership[workspaceId] = ownedRoots
                    ownershipByPID[childPID] = ownership
                    pending.append((childPID, workspaceId, root))
                }
            }
        }

        var completenessByWorkspace = rootValidation.completenessByWorkspace
        if processScan.completeness == .incomplete {
            for workspaceId in agentRootsByWorkspace.keys {
                completenessByWorkspace[workspaceId] = .incomplete
            }
        }
        return (ownershipByPID, completenessByWorkspace)
    }

    func revalidateAgentProcessTree(
        _ ownershipByPID: [Int: [UUID: Set<AgentPortRootIdentity>]],
        rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]
    ) -> (
        values: [Int: [UUID: Set<AgentPortRootIdentity>]],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        let rootValidation = validateAgentRoots(rootsByWorkspace)
        let filtered = ownershipByPID.reduce(
            into: [Int: [UUID: Set<AgentPortRootIdentity>]]()
        ) { partial, item in
            var validOwnership: [UUID: Set<AgentPortRootIdentity>] = [:]
            for (workspaceId, roots) in item.value {
                let validRoots = roots.intersection(rootValidation.values[workspaceId] ?? [])
                if !validRoots.isEmpty {
                    validOwnership[workspaceId] = validRoots
                }
            }
            if !validOwnership.isEmpty {
                partial[item.key] = validOwnership
            }
        }
        return (filtered, rootValidation.completenessByWorkspace)
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
                    completenessByWorkspace[workspaceId] = .incomplete
                    continue
                }
                guard let currentIdentity = processIdentityProvider(pid_t(root.pid)) else {
                    completenessByWorkspace[workspaceId] = .incomplete
                    continue
                }
                guard currentIdentity == expectedIdentity else { continue }
                validRootsByWorkspace[workspaceId, default: []].insert(root)
            }
        }
        return (validRootsByWorkspace, completenessByWorkspace)
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
        ownershipByPID: [Int: [UUID: Set<AgentPortRootIdentity>]],
        lsofScan: PortLsofScanResult,
        workspaceIds: Set<UUID>
    ) -> [UUID: PortScanCompleteness] {
        var pidsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ownership) in ownershipByPID {
            for workspaceId in ownership.keys {
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
        let complete = Self.isComplete(result) && parsedEveryRow
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
                    parsedEveryRow = false
                    continue
                }
                let portText = name[name.index(after: colon)...]
                guard portText.allSatisfy(\.isNumber),
                      let port = Int(portText),
                      port > 0,
                      port <= 65_535 else {
                    parsedEveryRow = false
                    continue
                }
                portsByPID[currentPID, default: []].insert(port)
            case "f":
                if line.dropFirst().isEmpty { parsedEveryRow = false }
            default:
                parsedEveryRow = false
            }
        }
        // lsof exits 1 both for "no selected files" and when one requested PID
        // disappears. Keep the failure scoped to the PIDs that can no longer be
        // inspected so unrelated workspaces can still consume complete evidence.
        let requestedPIDs = Set(pidsCsv.split(separator: ",").compactMap { Int($0) })
        let incompletePIDs = Set(requestedPIDs.filter {
            processIdentityProvider(pid_t($0)) == nil
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
}
