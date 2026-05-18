import Foundation

extension CMUXCLI {
    struct MemoryGracefulExitAction {
        let label: String
        let text: String
        let surfaceHandle: String
    }

    struct MemoryAgentParser {
        let cli: CMUXCLI

        func workspaceNode(from payload: [String: Any], matching workspaceHandle: String?) -> [String: Any]? {
            let windows = payload["windows"] as? [[String: Any]] ?? []
            var firstWorkspace: [String: Any]?
            for window in windows {
                let workspaces = window["workspaces"] as? [[String: Any]] ?? []
                for workspace in workspaces {
                    if firstWorkspace == nil {
                        firstWorkspace = workspace
                    }
                    if workspaceMatchesHandle(workspace, handle: workspaceHandle) {
                        return workspace
                    }
                }
            }
            return workspaceHandle == nil ? firstWorkspace : nil
        }

        func candidates(in workspace: [String: Any]) -> [MemoryAgentCandidate] {
            var byPID: [Int: MemoryAgentCandidate] = [:]
            let processIndex = memoryProcessIndex(in: workspace)

            for tag in workspace["tags"] as? [[String: Any]] ?? [] {
                guard let pid = CMUXCLI.topIntValue(tag["pid"]),
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
                    residentBytes: CMUXCLI.topInt64Value(resources["resident_bytes"]),
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

        func selectCandidate(
            _ candidates: [MemoryAgentCandidate],
            requested: String?
        ) throws -> MemoryAgentCandidate? {
            guard let requestedRaw = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedRaw.isEmpty,
                  requestedRaw.lowercased() != "auto" else {
                return candidates.first { $0.owned }
            }
            if let pid = Int(requestedRaw) {
                guard let candidate = candidates.first(where: { $0.pid == pid }) else {
                    return nil
                }
                guard candidate.owned else {
                    throw CLIError(message: "memory trim refused PID \(pid) because it is not a cmux-owned recoverable agent")
                }
                return candidate
            }
            let normalized = memoryAgentKey(for: requestedRaw) ?? requestedRaw.lowercased()
            guard let candidate = candidates.first(where: {
                $0.key == normalized ||
                    $0.processName?.lowercased() == normalized
            }) else {
                return nil
            }
            guard candidate.owned else {
                throw CLIError(message: "memory trim refused agent '\(requestedRaw)' because it is not a cmux-owned recoverable agent")
            }
            return candidate
        }

        func noAgentMessage(candidates: [MemoryAgentCandidate], requested: String?) -> String {
            let recoverableCandidates = candidates.filter(\.owned)
            if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let available = recoverableCandidates.map { "\($0.key):\($0.pid)" }.joined(separator: ", ")
                return available.isEmpty
                    ? "memory trim found no recoverable agent PIDs in this workspace"
                    : "memory trim could not find agent '\(requested)'. Available: \(available)"
            }
            return "memory trim found no cmux-owned recoverable agent PIDs in this workspace"
        }

        func matchesOriginal(_ candidate: MemoryAgentCandidate, original: MemoryAgentCandidate) -> Bool {
            guard candidate.pid == original.pid,
                  candidate.key == original.key,
                  candidate.identity == original.identity,
                  candidate.owned else {
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

        func gracefulExitAction(for candidate: MemoryAgentCandidate) -> MemoryGracefulExitAction? {
            guard let graceful = memoryGracefulExit(for: candidate),
                  let surfaceHandle = candidate.surfaceId ?? candidate.surfaceRef else {
                return nil
            }
            return MemoryGracefulExitAction(
                label: graceful.label,
                text: graceful.text,
                surfaceHandle: surfaceHandle
            )
        }

        private func workspaceMatchesHandle(_ workspace: [String: Any], handle: String?) -> Bool {
            guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
                return false
            }
            return (workspace["id"] as? String) == handle || (workspace["ref"] as? String) == handle
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
            if let pid = CMUXCLI.topIntValue(process["pid"]) {
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
            if let pid = CMUXCLI.topIntValue(process["pid"]) {
                let name = cli.topLabelText(process["name"] as? String)
                if let key = memoryAgentKey(for: name) {
                    let resources = process["resources"] as? [String: Any] ?? [:]
                    let candidate = MemoryAgentCandidate(
                        key: key,
                        pid: pid,
                        surfaceId: surfaceId,
                        surfaceRef: surfaceRef,
                        processName: name,
                        residentBytes: CMUXCLI.topInt64Value(resources["resident_bytes"]),
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
    }
}
