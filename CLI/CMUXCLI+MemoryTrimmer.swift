import Darwin
import Foundation

extension CMUXCLI {
    struct MemoryProcessIdentity: Equatable {
        let pid: Int
        let startSeconds: Int
        let startMicroseconds: Int

        var payload: [String: Any] {
            [
                "pid": pid,
                "start_seconds": startSeconds,
                "start_microseconds": startMicroseconds
            ]
        }

        init?(process: [String: Any]) {
            guard let pid = Self.int(process["pid"]),
                  let startSeconds = Self.int(process["start_seconds"]),
                  let startMicroseconds = Self.int(process["start_microseconds"]) else {
                return nil
            }
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }

        private static func int(_ raw: Any?) -> Int? {
            if let value = raw as? Int { return value }
            if let value = raw as? Int64 { return Int(exactly: value) }
            if let value = raw as? Double { return value.isFinite ? Int(value) : nil }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }
    }

    enum MemoryAgentCandidateSource: String {
        case tag
        case process
    }

    struct MemoryAgentCandidate {
        let key: String
        let pid: Int
        let surfaceId: String?
        let surfaceRef: String?
        let processName: String?
        let residentBytes: Int64
        let source: MemoryAgentCandidateSource
        let identity: MemoryProcessIdentity?

        var owned: Bool {
            source == .tag
        }

        var displayName: String {
            processName.map { "\(key) (\($0))" } ?? key
        }

        var payload: [String: Any] {
            [
                "key": key,
                "pid": pid,
                "surface_id": surfaceId ?? NSNull(),
                "surface_ref": surfaceRef ?? NSNull(),
                "process_name": processName ?? NSNull(),
                "resident_bytes": residentBytes,
                "owned": owned,
                "process_identity": identity?.payload ?? NSNull()
            ]
        }
    }

    struct MemoryTrimResult {
        let workspaceId: String
        let workspaceRef: String?
        let agent: MemoryAgentCandidate
        let gracefulAction: String?
        let terminated: Bool
        let killed: Bool
        let stillRunning: Bool
        let dryRun: Bool

        var payload: [String: Any] {
            [
                "workspace_id": workspaceId,
                "workspace_ref": workspaceRef ?? NSNull(),
                "agent": agent.payload,
                "graceful_action": gracefulAction ?? NSNull(),
                "terminated": terminated,
                "killed": killed,
                "still_running": stillRunning,
                "dry_run": dryRun
            ]
        }
    }

    struct MemoryTrimmer {
        let cli: CMUXCLI
        let client: SocketClient

        func trim(options: MemoryTrimCommandOptions) throws -> MemoryTrimResult {
            let workspaceHandle = try cli.normalizeWorkspaceHandle(
                options.workspaceHandle,
                client: client,
                allowCurrent: true
            )
            guard let workspaceHandle else {
                throw CLIError(message: "memory trim requires --workspace <id|ref|index> or a current workspace")
            }
            let payload = try cli.buildMemoryTopPayload(workspaceHandle: workspaceHandle, client: client)
            guard let workspace = memoryWorkspaceNode(from: payload) else {
                throw CLIError(message: "Workspace not found")
            }
            let workspaceId = (workspace["id"] as? String) ?? workspaceHandle
            let workspaceRef = workspace["ref"] as? String
            let candidates = memoryAgentCandidates(in: workspace)
            guard let candidate = selectMemoryAgentCandidate(candidates, requested: options.agent) else {
                throw CLIError(message: memoryNoAgentMessage(candidates: candidates, requested: options.agent))
            }

            let graceful = memoryGracefulExit(for: candidate)
            var gracefulAction: String?
            var terminated = false
            var killed = false

            if !options.dryRun {
                if let graceful,
                   let surfaceHandle = candidate.surfaceRef ?? candidate.surfaceId {
                    let params: [String: Any] = [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceHandle,
                        "text": graceful.text
                    ]
                    _ = try client.sendV2(method: "surface.send_text", params: params)
                    gracefulAction = graceful.label
                    _ = waitForProcessExit(pid: candidate.pid, timeout: options.graceSeconds)
                }

                if let liveCandidate = try revalidatedSignalCandidate(
                    matching: candidate,
                    workspaceHandle: workspaceHandle
                ) {
                    if Darwin.kill(pid_t(liveCandidate.pid), SIGTERM) == 0 {
                        terminated = true
                    }
                    _ = waitForProcessExit(pid: liveCandidate.pid, timeout: options.graceSeconds)
                }

                if let liveCandidate = try revalidatedSignalCandidate(
                    matching: candidate,
                    workspaceHandle: workspaceHandle
                ) {
                    if Darwin.kill(pid_t(liveCandidate.pid), SIGKILL) == 0 {
                        killed = true
                    }
                    _ = waitForProcessExit(pid: liveCandidate.pid, timeout: 1)
                }
            } else {
                gracefulAction = graceful?.label
            }

            let stillRunning = options.dryRun
                ? isProcessRunning(pid: candidate.pid)
                : (try revalidatedSignalCandidate(matching: candidate, workspaceHandle: workspaceHandle)) != nil

            return MemoryTrimResult(
                workspaceId: workspaceId,
                workspaceRef: workspaceRef,
                agent: candidate,
                gracefulAction: gracefulAction,
                terminated: terminated,
                killed: killed,
                stillRunning: stillRunning,
                dryRun: options.dryRun
            )
        }

        private func revalidatedSignalCandidate(
            matching original: MemoryAgentCandidate,
            workspaceHandle: String
        ) throws -> MemoryAgentCandidate? {
            guard isProcessRunning(pid: original.pid) else { return nil }
            guard original.identity != nil else {
                throw CLIError(message: "memory trim refused to signal PID \(original.pid) because system.top did not include a process identity")
            }

            let payload = try cli.buildMemoryTopPayload(workspaceHandle: workspaceHandle, client: client)
            guard let workspace = memoryWorkspaceNode(from: payload),
                  let candidate = memoryAgentCandidates(in: workspace).first(where: { matchesOriginal($0, original: original) }) else {
                guard isProcessRunning(pid: original.pid) else { return nil }
                throw CLIError(message: "memory trim refused to signal PID \(original.pid) because system.top could not revalidate the process identity")
            }
            return candidate
        }

        private func matchesOriginal(_ candidate: MemoryAgentCandidate, original: MemoryAgentCandidate) -> Bool {
            guard candidate.pid == original.pid,
                  candidate.key == original.key,
                  candidate.identity == original.identity else {
                return false
            }
            if let surfaceId = original.surfaceId, candidate.surfaceId != surfaceId {
                return false
            }
            if let surfaceRef = original.surfaceRef, candidate.surfaceRef != surfaceRef {
                return false
            }
            return true
        }

        private func memoryWorkspaceNode(from payload: [String: Any]) -> [String: Any]? {
            let windows = payload["windows"] as? [[String: Any]] ?? []
            for window in windows {
                let workspaces = window["workspaces"] as? [[String: Any]] ?? []
                if let workspace = workspaces.first {
                    return workspace
                }
            }
            return nil
        }

        private func memoryAgentCandidates(in workspace: [String: Any]) -> [MemoryAgentCandidate] {
            var byPID: [Int: MemoryAgentCandidate] = [:]
            let processIndex = memoryProcessIndex(in: workspace)

            for tag in workspace["tags"] as? [[String: Any]] ?? [] {
                guard let pid = Self.int(tag["pid"]),
                      let rawKey = tag["key"] as? String,
                      let key = memoryAgentKey(for: rawKey) else {
                    continue
                }
                let process = processIndex[pid]
                let resources = (process?["resources"] as? [String: Any]) ?? (tag["resources"] as? [String: Any] ?? [:])
                let processName = cli.topLabelText(process?["name"] as? String)
                let candidate = MemoryAgentCandidate(
                    key: key,
                    pid: pid,
                    surfaceId: tag["surface_id"] as? String,
                    surfaceRef: tag["surface_ref"] as? String,
                    processName: processName.isEmpty ? nil : processName,
                    residentBytes: Self.int64(resources["resident_bytes"]),
                    source: .tag,
                    identity: process.flatMap { MemoryProcessIdentity(process: $0) }
                )
                byPID[pid] = preferredMemoryCandidate(candidate, over: byPID[pid])
            }

            for pane in workspace["panes"] as? [[String: Any]] ?? [] {
                for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                    collectMemoryAgentCandidates(
                        fromProcessesIn: surface,
                        surfaceId: surface["id"] as? String,
                        surfaceRef: surface["ref"] as? String,
                        into: &byPID
                    )
                }
            }

            return byPID.values.sorted {
                if $0.owned != $1.owned { return $0.owned && !$1.owned }
                if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
                return $0.pid < $1.pid
            }
        }

        private func memoryProcessIndex(in workspace: [String: Any]) -> [Int: [String: Any]] {
            var result: [Int: [String: Any]] = [:]
            indexMemoryProcesses(fromProcessesIn: workspace, into: &result)
            for tag in workspace["tags"] as? [[String: Any]] ?? [] {
                indexMemoryProcesses(fromProcessesIn: tag, into: &result)
            }
            for pane in workspace["panes"] as? [[String: Any]] ?? [] {
                indexMemoryProcesses(fromProcessesIn: pane, into: &result)
                for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                    indexMemoryProcesses(fromProcessesIn: surface, into: &result)
                    for webview in surface["webviews"] as? [[String: Any]] ?? [] {
                        indexMemoryProcesses(fromProcessesIn: webview, into: &result)
                    }
                }
            }
            return result
        }

        private func indexMemoryProcesses(fromProcessesIn node: [String: Any], into result: inout [Int: [String: Any]]) {
            for process in node["processes"] as? [[String: Any]] ?? [] {
                indexMemoryProcess(process, into: &result)
            }
        }

        private func indexMemoryProcess(_ process: [String: Any], into result: inout [Int: [String: Any]]) {
            if let pid = Self.int(process["pid"]) {
                result[pid] = process
            }
            for child in process["children"] as? [[String: Any]] ?? [] {
                indexMemoryProcess(child, into: &result)
            }
        }

        private func collectMemoryAgentCandidates(
            fromProcessesIn node: [String: Any],
            surfaceId: String?,
            surfaceRef: String?,
            into byPID: inout [Int: MemoryAgentCandidate]
        ) {
            for process in node["processes"] as? [[String: Any]] ?? [] {
                collectMemoryAgentCandidate(
                    from: process,
                    surfaceId: surfaceId,
                    surfaceRef: surfaceRef,
                    into: &byPID
                )
            }
        }

        private func collectMemoryAgentCandidate(
            from process: [String: Any],
            surfaceId: String?,
            surfaceRef: String?,
            into byPID: inout [Int: MemoryAgentCandidate]
        ) {
            if let pid = Self.int(process["pid"]) {
                let name = cli.topLabelText(process["name"] as? String)
                if let key = memoryAgentKey(for: name) {
                    let resources = process["resources"] as? [String: Any] ?? [:]
                    let candidate = MemoryAgentCandidate(
                        key: key,
                        pid: pid,
                        surfaceId: surfaceId,
                        surfaceRef: surfaceRef,
                        processName: name,
                        residentBytes: Self.int64(resources["resident_bytes"]),
                        source: .process,
                        identity: MemoryProcessIdentity(process: process)
                    )
                    byPID[pid] = preferredMemoryCandidate(candidate, over: byPID[pid])
                }
            }
            for child in process["children"] as? [[String: Any]] ?? [] {
                collectMemoryAgentCandidate(
                    from: child,
                    surfaceId: surfaceId,
                    surfaceRef: surfaceRef,
                    into: &byPID
                )
            }
        }

        private func preferredMemoryCandidate(
            _ candidate: MemoryAgentCandidate,
            over existing: MemoryAgentCandidate?
        ) -> MemoryAgentCandidate {
            guard let existing else { return candidate }
            if existing.owned != candidate.owned {
                return candidate.owned ? candidate : existing
            }
            if existing.surfaceId == nil && candidate.surfaceId != nil {
                return candidate
            }
            if existing.identity == nil && candidate.identity != nil {
                return candidate
            }
            if candidate.residentBytes > existing.residentBytes {
                return candidate
            }
            return existing
        }

        private func selectMemoryAgentCandidate(
            _ candidates: [MemoryAgentCandidate],
            requested: String?
        ) -> MemoryAgentCandidate? {
            guard let requestedRaw = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedRaw.isEmpty,
                  requestedRaw.lowercased() != "auto" else {
                return candidates.first { $0.owned }
            }
            if let pid = Int(requestedRaw) {
                return candidates.first { $0.pid == pid }
            }
            let normalized = memoryAgentKey(for: requestedRaw) ?? requestedRaw.lowercased()
            return candidates.first {
                $0.key == normalized ||
                    $0.processName?.lowercased() == normalized
            }
        }

        private func memoryNoAgentMessage(candidates: [MemoryAgentCandidate], requested: String?) -> String {
            if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let available = candidates.map { "\($0.key):\($0.pid)" }.joined(separator: ", ")
                return available.isEmpty
                    ? "memory trim found no recoverable agent PIDs in this workspace"
                    : "memory trim could not find agent '\(requested)'. Available: \(available)"
            }
            return "memory trim found no cmux-owned recoverable agent PIDs in this workspace"
        }

        private func memoryAgentKey(for raw: String) -> String? {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { return nil }
            if normalized == "claude" || normalized == "claude-code" || normalized == "claude-code-cli" {
                return "claude"
            }
            for def in CMUXCLI.agentDefs {
                if normalized == def.name ||
                    normalized == def.binaryName.lowercased() ||
                    def.aliases.contains(normalized) {
                    return def.name
                }
            }
            return nil
        }

        private func memoryGracefulExit(for candidate: MemoryAgentCandidate) -> (label: String, text: String)? {
            switch candidate.key {
            case "claude":
                return ("send /exit", "/exit\r")
            case "codex":
                return ("send /quit", "/quit\r")
            default:
                return nil
            }
        }

        private func waitForProcessExit(pid: Int, timeout: TimeInterval) -> Bool {
            guard pid > 0 else { return true }
            guard timeout > 0 else { return !isProcessRunning(pid: pid) }
            guard isProcessRunning(pid: pid) else { return true }

            let queue = kqueue()
            guard queue >= 0 else { return !isProcessRunning(pid: pid) }
            defer { Darwin.close(queue) }

            var change = kevent(
                ident: UInt(pid),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil
            )
            if kevent(queue, &change, 1, nil, 0, nil) == -1 {
                return !isProcessRunning(pid: pid)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return !isProcessRunning(pid: pid) }
                let seconds = floor(remaining)
                var timeoutSpec = timespec(
                    tv_sec: Int(seconds),
                    tv_nsec: Int((remaining - seconds) * 1_000_000_000)
                )
                var event = kevent()
                let result = kevent(queue, nil, 0, &event, 1, &timeoutSpec)
                if result > 0 {
                    return true
                }
                if result == 0 {
                    return !isProcessRunning(pid: pid)
                }
                if errno != EINTR {
                    return !isProcessRunning(pid: pid)
                }
            }
        }

        private func isProcessRunning(pid: Int) -> Bool {
            guard pid > 0 else { return false }
            if Darwin.kill(pid_t(pid), 0) == 0 {
                return true
            }
            return errno == EPERM
        }

        private static func int(_ raw: Any?) -> Int? {
            if let value = raw as? Int { return value }
            if let value = raw as? Int64 { return Int(exactly: value) }
            if let value = raw as? Double { return value.isFinite ? Int(value) : nil }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }

        private static func int64(_ raw: Any?) -> Int64 {
            if let value = raw as? Int64 { return value }
            if let value = raw as? Int { return Int64(value) }
            if let value = raw as? Double { return value.isFinite ? Int64(value) : 0 }
            if let value = raw as? NSNumber { return value.int64Value }
            if let value = raw as? String {
                return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            return 0
        }
    }
}
