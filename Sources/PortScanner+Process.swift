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

    func expandAgentProcessTree(
        agentPIDsByWorkspace: [UUID: Set<Int>]
    ) async -> (values: [Int: Set<UUID>], completeness: PortScanCompleteness) {
        let normalizedRoots = agentPIDsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            let valid = Set(item.value.filter { $0 > 0 })
            guard !valid.isEmpty else { return }
            partial[item.key] = valid
        }
        guard !normalizedRoots.isEmpty else { return ([:], .complete) }

        var pidToWorkspaces: [Int: Set<UUID>] = [:]
        var pending: [(pid: Int, workspaceId: UUID)] = []
        for (workspaceId, roots) in normalizedRoots {
            for pid in roots where pidToWorkspaces[pid, default: []].insert(workspaceId).inserted {
                pending.append((pid, workspaceId))
            }
        }

        let processScan = await runAllProcesses()
        var childrenByParent: [Int: [Int]] = [:]
        for (pid, parentPid) in processScan.values {
            childrenByParent[parentPid, default: []].append(pid)
        }

        var index = 0
        while index < pending.count {
            let (pid, workspaceId) = pending[index]
            index += 1
            for childPid in childrenByParent[pid] ?? []
                where pidToWorkspaces[childPid, default: []].insert(workspaceId).inserted {
                pending.append((childPid, workspaceId))
            }
        }

        return (pidToWorkspaces, processScan.completeness)
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

    func runLsof(pidsCsv: String) async -> (values: [Int: Set<Int>], completeness: PortScanCompleteness) {
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
        // lsof exits 1 both for "no selected files" and when a PID disappeared
        // between ps and lsof. Only the former is authoritative negative evidence.
        let requestedPIDs = pidsCsv.split(separator: ",").compactMap { Int32($0) }
        let emptyResultIsAuthoritative =
            (result.stdout ?? "").isEmpty
            && (result.stderr ?? "").isEmpty
            && requestedPIDs.allSatisfy(Self.canInspectProcess)
        let completeness: PortScanCompleteness =
            (Self.isComplete(result) && parsedEveryRow)
            || (result.exitStatus == 1 && emptyResultIsAuthoritative)
            ? .complete
            : .incomplete
        return (portsByPID, completeness)
    }

    private static func isComplete(_ result: CommandResult) -> Bool {
        result.executionError == nil
            && !result.timedOut
            && result.exitStatus == 0
            && (result.stderr ?? "").isEmpty
    }

    private static func canInspectProcess(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // EPERM proves that the process exists, but not that lsof could inspect
        // it. Treat permission-denied probes as incomplete instead of turning
        // an inaccessible process into authoritative negative port evidence.
        return kill(pid, 0) == 0
    }
}
