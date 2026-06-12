internal import Foundation

/// Terminal history-panel commands lifted into the sidebar/reporting v1
/// coordinator alongside `report_shell_state`.
extension ControlCommandCoordinator {
    /// `report_command_history` — record one executed command for the terminal
    /// history menu.
    func sidebarReportCommandHistory(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        let parsed = sidebarParseOptions(args)
        let usage = "report_command_history --encoding=base64 [--tab=X] [--panel=Y] -- <payload>"
        let encoding = (parsed.options["encoding"] ?? "base64")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard encoding == "base64" else {
            return "ERROR: Unsupported command history encoding '\(encoding)' — usage: \(usage)"
        }
        guard let payload = parsed.positional.first, !payload.isEmpty else {
            return "ERROR: Missing command history payload — usage: \(usage)"
        }
        guard let data = Data(base64Encoded: payload),
              let command = String(data: data, encoding: .utf8) else {
            return "ERROR: Invalid command history payload — expected base64 UTF-8"
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ERROR: Empty command history payload"
        }

        let resolution = sidebarContext?.controlSidebarRecordCommandHistory(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"],
            command: command
        ) ?? .tabNotFound
        return historyPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: usage
        )
    }

    /// `report_command_history_snapshot` — replace the panel's menu source
    /// with the shell-native history snapshot.
    func sidebarReportCommandHistorySnapshot(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        let parsed = sidebarParseOptions(args)
        let usage = "report_command_history_snapshot --encoding=base64 [--shell=X] [--tab=X] [--panel=Y] -- <payload>"
        let encoding = (parsed.options["encoding"] ?? "base64")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard encoding == "base64" else {
            return "ERROR: Unsupported command history snapshot encoding '\(encoding)' — usage: \(usage)"
        }
        guard let payload = parsed.positional.first, !payload.isEmpty else {
            return "ERROR: Missing command history snapshot payload — usage: \(usage)"
        }
        guard let data = Data(base64Encoded: payload) else {
            return "ERROR: Invalid command history snapshot payload — expected base64"
        }
        let snapshot = String(decoding: data, as: UTF8.self)

        let resolution = sidebarContext?.controlSidebarReplaceCommandHistorySnapshot(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"],
            shell: parsed.options["shell"],
            snapshot: snapshot
        ) ?? .tabNotFound
        return historyPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: usage
        )
    }

    private func historyPanelWriteReply(
        _ resolution: ControlSidebarPanelWriteResolution,
        hasTabOption: Bool,
        missingPanelUsage: String
    ) -> String {
        switch resolution {
        case .tabNotFound:
            return hasTabOption ? "ERROR: Tab not found" : "ERROR: No tab selected"
        case .missingPanelArg:
            return "ERROR: Missing panel id — usage: \(missingPanelUsage)"
        case .invalidPanelArg(let panelArg):
            return "ERROR: Invalid panel id '\(panelArg)'"
        case .noFocusedPanel:
            return "ERROR: Missing panel id (no focused surface)"
        case .panelNotFound(let surfaceId):
            return "ERROR: Panel not found '\(surfaceId.uuidString)'"
        case .done:
            return "OK"
        }
    }
}
