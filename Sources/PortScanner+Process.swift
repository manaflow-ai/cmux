import CmuxCore
import Darwin
import Foundation

extension PortScanner {
    static func combinedCompleteness(
        _ lhs: PortScanCompleteness,
        _ rhs: PortScanCompleteness
    ) -> PortScanCompleteness {
        lhs == .complete && rhs == .complete ? .complete : .incomplete
    }

    static func captureStandardOutput(executablePath: String, arguments: [String]) -> String? {
        captureProcess(executablePath: executablePath, arguments: arguments)?.stdout
    }

    static func captureProcess(
        executablePath: String,
        arguments: [String]
    ) -> (stdout: String, status: Int32)? {
        autoreleasepool {
            let process = Process()
            let stdoutPipe = Pipe()
            let stdoutReadHandle = stdoutPipe.fileHandleForReading
            let stdoutWriteHandle = stdoutPipe.fileHandleForWriting

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            defer {
                try? stdoutReadHandle.close()
                try? stdoutWriteHandle.close()
            }

            do {
                try process.run()
            } catch {
                return nil
            }

            // The reader reaches EOF only after the parent closes its write end.
            try? stdoutWriteHandle.close()
            let data = stdoutReadHandle.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return (output, process.terminationStatus)
        }
    }

    func expandAgentProcessTree(
        agentPIDsByWorkspace: [UUID: Set<Int>]
    ) -> (values: [Int: Set<UUID>], completeness: PortScanCompleteness) {
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

        let processScan = runAllProcesses()
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

    func runPS(ttyList: String) -> (values: [Int: String], completeness: PortScanCompleteness) {
        guard let result = Self.captureProcess(
            executablePath: "/bin/ps",
            arguments: ["-t", ttyList, "-o", "pid=,tty="]
        ) else { return ([:], .incomplete) }

        var mapping: [Int: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
            mapping[pid] = String(parts[1])
        }
        return (mapping, result.status == 0 ? .complete : .incomplete)
    }

    func runAllProcesses() -> (values: [Int: Int], completeness: PortScanCompleteness) {
        guard let result = Self.captureProcess(
            executablePath: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,ppid="]
        ) else { return ([:], .incomplete) }

        var mapping: [Int: Int] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int(parts[0]),
                  let parentPid = Int(parts[1]) else { continue }
            mapping[pid] = parentPid
        }
        return (mapping, result.status == 0 ? .complete : .incomplete)
    }

    func runLsof(pidsCsv: String) -> (values: [Int: Set<Int>], completeness: PortScanCompleteness) {
        guard let result = Self.captureProcess(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", pidsCsv, "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        ) else { return ([:], .incomplete) }

        var portsByPID: [Int: Set<Int>] = [:]
        var currentPID: Int?
        for line in result.stdout.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPID = Int(line.dropFirst())
            case "n":
                guard let currentPID else { continue }
                var name = String(line.dropFirst())
                if let arrow = name.range(of: "->") {
                    name = String(name[..<arrow.lowerBound])
                }
                guard let colon = name.lastIndex(of: ":") else { continue }
                let digits = name[name.index(after: colon)...].prefix(while: \.isNumber)
                if let port = Int(digits), port > 0, port <= 65_535 {
                    portsByPID[currentPID, default: []].insert(port)
                }
            default:
                break
            }
        }
        // lsof exits 1 both for "no selected files" and when a PID disappeared
        // between ps and lsof. Only the former is authoritative negative evidence.
        let requestedPIDs = pidsCsv.split(separator: ",").compactMap { Int32($0) }
        let emptyResultIsAuthoritative = result.stdout.isEmpty && requestedPIDs.allSatisfy(Self.isProcessLive)
        let completeness: PortScanCompleteness =
            result.status == 0 || (result.status == 1 && emptyResultIsAuthoritative)
            ? .complete
            : .incomplete
        return (portsByPID, completeness)
    }

    private static func isProcessLive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
