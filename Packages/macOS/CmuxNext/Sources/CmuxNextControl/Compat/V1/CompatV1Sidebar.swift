import CmuxNextDaemon
import Foundation

/// Sidebar metadata v1 verbs (`cmux set-status`, `set-progress`, `log`,
/// `sidebar-state`, hooks' `set_agent_pid`, shell integration `report_*`).
enum CompatV1Sidebar {
    static let handlers: [String: CompatV1.Handler] = [
        "set_status": setStatus,
        "clear_status": { line, service in
            guard let key = line.positional.first else { return "ERROR: usage: clear_status <key>" }
            service.sidebar.clearStatus(key, workspace: try await workspace(line, service).uuid)
            return "OK"
        },
        "list_status": listStatus,
        "set_progress": setProgress,
        "clear_progress": { line, service in
            service.sidebar.setProgress(nil, workspace: try await workspace(line, service).uuid)
            return "OK"
        },
        "log": log,
        "clear_log": { line, service in
            service.sidebar.clearLog(workspace: try await workspace(line, service).uuid)
            return "OK"
        },
        "list_log": listLog,
        "sidebar_state": sidebarState,
        "set_agent_pid": { line, service in
            guard line.positional.count >= 2, let pid = Int(line.positional[1]) else { return "ERROR: usage: set_agent_pid <key> <pid>" }
            service.sidebar.setAgentPID(line.positional[0], pid, workspace: try await workspace(line, service).uuid)
            return "OK"
        },
        "clear_agent_pid": { line, service in
            guard let key = line.positional.first else { return "ERROR: usage: clear_agent_pid <key>" }
            let uuid = try await workspace(line, service).uuid
            service.sidebar.setAgentPID(key, nil, workspace: uuid)
            if line.has("clear-status") { service.sidebar.clearStatus(key, workspace: uuid) }
            return "OK"
        },
        // cmux-tui derives cwd (OSC 7) and git branch per tab itself
        // (`tab-metadata-v1`), so shell-integration reports have no second
        // owner to update. Accepted so shells never print errors.
        "report_pwd": { _, _ in "OK" },
        "report_git_branch": { _, _ in "OK" },
        "clear_git_branch": { _, _ in "OK" },
        "report_tty": { _, _ in "OK" },
        "ports_kick": { _, _ in "OK" },
        "report_pr": { _, _ in "OK" },
        "clear_pr": { _, _ in "OK" },
    ]

    /// `--tab=<UUID|index|ref>`, else the active window's workspace.
    static func workspace(_ line: CompatV1Line, _ service: CompatService) async throws -> CompatWorld.Workspace {
        let world = try await service.world()
        if let tab = line.option("tab") ?? line.option("workspace") {
            guard let found = try? world.resolveWorkspace(tab, refs: service.refs) else { throw CompatErrors.invalid(ControlStrings.text("control.error.tabNotFound", "Tab not found")) }
            return found
        }
        guard let current = world.currentWorkspace(window: world.activeWindow) else { throw CompatErrors.invalid(ControlStrings.text("control.error.noTabSelected", "No tab selected")) }
        return current
    }

    static func setStatus(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        guard line.positional.count >= 2 else { return "ERROR: usage: set_status <key> <value> [--icon=X] [--color=#hex]" }
        var priority: Int?
        if let raw = line.option("priority") {
            guard let value = Int(raw), abs(value) <= 9999 else { return "ERROR: priority must be an integer in -9999...9999" }
            priority = value
        }
        if let url = line.option("url"), !(url.hasPrefix("http://") || url.hasPrefix("https://")) {
            return "ERROR: url must be http(s)"
        }
        let status = CompatSidebarStore.Status(value: line.rest(after: 1), icon: line.option("icon"), color: line.option("color"),
                                               url: line.option("url"), priority: priority, format: line.option("format"))
        service.sidebar.setStatus(line.positional[0], status, workspace: try await workspace(line, service).uuid)
        return "OK"
    }

    /// Highest priority first; entries without a priority keep insertion order after them.
    static func sortedStatuses(_ entry: CompatSidebarStore.Workspace) -> [(key: String, status: CompatSidebarStore.Status)] {
        entry.statuses.enumerated().sorted { lhs, rhs in
            let l = lhs.element.status.priority ?? Int.min
            let r = rhs.element.status.priority ?? Int.min
            return l != r ? l > r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func statusLine(_ key: String, _ status: CompatSidebarStore.Status) -> String {
        var text = "\(key)=\(status.value)"
        if let icon = status.icon { text += " icon=\(icon)" }
        if let color = status.color { text += " color=\(color)" }
        if let url = status.url { text += " url=\(url)" }
        if let priority = status.priority { text += " priority=\(priority)" }
        if status.format == "markdown" { text += " format=markdown" }
        return text
    }

    static func listStatus(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let entry = service.sidebar.workspace(try await workspace(line, service).uuid)
        let lines = sortedStatuses(entry).map { statusLine($0.key, $0.status) }
        return lines.isEmpty ? "No status entries" : lines.joined(separator: "\n")
    }

    static func setProgress(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        guard let raw = line.positional.first, let value = Double(raw), value.isFinite else {
            return "ERROR: usage: set_progress <0.0-1.0> [--label=X]"
        }
        service.sidebar.setProgress((min(max(value, 0), 1), line.option("label")), workspace: try await workspace(line, service).uuid)
        return "OK"
    }

    static let logLevels: Set<String> = ["info", "progress", "success", "warning", "error"]

    static func log(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let level = line.option("level")?.lowercased() ?? "info"
        guard logLevels.contains(level) else { return "ERROR: Unknown log level '\(level)'" }
        let message = (line.tail.isEmpty ? line.positional : line.tail).joined(separator: " ")
        guard !message.isEmpty else { return "ERROR: usage: log [--level=X] -- <message>" }
        service.sidebar.appendLog(CompatSidebarStore.LogLine(level: level, source: line.option("source"), message: message),
                                  workspace: try await workspace(line, service).uuid)
        return "OK"
    }

    static func logLine(_ entry: CompatSidebarStore.LogLine) -> String {
        "[\(entry.level)] " + (entry.source.map { "\($0): " } ?? "") + entry.message
    }

    static func listLog(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        var log = service.sidebar.workspace(try await workspace(line, service).uuid).log
        if let limit = line.option("limit").flatMap(Int.init), limit >= 0 { log = Array(log.suffix(limit)) }
        return log.isEmpty ? "No log entries" : log.map(logLine).joined(separator: "\n")
    }

    static func sidebarState(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let world = try await service.world()
        let workspace = try await workspace(line, service)
        let entry = service.sidebar.workspace(workspace.uuid)
        let focus = world.focus(in: workspace)
        let cwd: String = focus.surface?.tab.cwd ?? "none"
        let branch: String = focus.surface?.tab.gitBranch.map { "\($0) unknown" } ?? "none"
        var progress = "none"
        if let value = entry.progress {
            progress = String(format: "%.2f", value.value)
            if let label = value.label { progress += " " + label }
        }
        var lines: [String] = [
            "tab=\(workspace.uuid)",
            "color=\(workspace.color ?? "none")",
            "cwd=\(cwd)",
            "focused_cwd=\(cwd)",
            "focused_panel=\(focus.surface?.uuid ?? "none")",
            "git_branch=\(branch)",
            "pr=none", "pr_label=none", "ports=none",
            "progress=\(progress)",
            "status_count=\(entry.statuses.count)",
        ]
        lines += sortedStatuses(entry).map { "  " + statusLine($0.key, $0.status) }
        lines.append("meta_block_count=0")
        lines.append("log_count=\(entry.log.count)")
        lines += entry.log.map { "  " + logLine($0) }
        return lines.joined(separator: "\n")
    }
}
