internal import Foundation

/// The v1 sidebar telemetry/report commands (`report_git_branch` / `report_pr`
/// / `report_ports` / `report_pwd` / `report_shell_state` / `report_tty` /
/// `ports_kick` / `sidebar_state` / `reset_sidebar` / `right_sidebar`), lifted
/// byte-faithfully from the former `TerminalController` bodies.
extension ControlCommandCoordinator {
    // MARK: - Git branch

    /// `report_git_branch` — record the reported git branch.
    func sidebarReportGitBranch(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard let branch = parsed.positional.first else {
            return "ERROR: Missing branch name — usage: report_git_branch <branch> [--status=dirty|clean|unknown] [--tab=X]"
        }
        let status = parsed.options["status"]?.lowercased()
        let isDirty: Bool? = {
            switch status {
            case "dirty":
                return true
            case "unknown":
                return nil
            default:
                return false
            }
        }()

        // Shell integration always includes explicit workspace/panel IDs.
        // Keep this telemetry path off-main so wake/main-thread stalls don't
        // block socket handlers and starve subsequent branch updates.
        if let scope = sidebarExplicitScope(options: parsed.options) {
            sidebarContext?.controlSidebarScheduleScopedGitBranchUpdate(scope: scope, branch: branch, isDirty: isDirty)
            return "OK"
        }

        guard sidebarContext?.controlSidebarUpdateGitBranch(
            tabArg: parsed.options["tab"],
            branch: branch,
            isDirty: isDirty
        ) ?? false else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_git_branch` — clear the reported git branch.
    func sidebarClearGitBranch(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)

        if let scope = sidebarExplicitScope(options: parsed.options) {
            sidebarContext?.controlSidebarScheduleScopedGitBranchClear(scope: scope)
            return "OK"
        }
        guard sidebarContext?.controlSidebarClearGitBranch(tabArg: parsed.options["tab"]) ?? false else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }

    // MARK: - Pull requests

    /// `report_pr` / `report_review` — record a pull request on a panel.
    func sidebarReportPullRequest(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard parsed.positional.count >= 2 else {
            return "ERROR: Missing pull request number or URL — usage: report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y]"
        }

        let rawNumber = parsed.positional[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let numberToken = rawNumber.hasPrefix("#") ? String(rawNumber.dropFirst()) : rawNumber
        guard let number = Int(numberToken), number > 0 else {
            return "ERROR: Invalid pull request number '\(rawNumber)'"
        }

        let rawURL = parsed.positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "ERROR: Invalid pull request URL '\(rawURL)'"
        }

        let statusRaw = (parsed.options["state"] ?? "open").lowercased()
        guard sidebarContext?.controlSidebarIsValidPullRequestState(statusRaw) ?? false else {
            return "ERROR: Invalid pull request state '\(statusRaw)' — use: open, merged, closed"
        }
        let branch = sidebarNormalizedOptionValue(parsed.options["branch"])
        if sidebarNormalizedOptionValue(parsed.options["checks"]) != nil {
            return "ERROR: Unsupported option '--checks' — pull request checks are no longer tracked"
        }

        let labelRaw = sidebarNormalizedOptionValue(parsed.options["label"]) ?? "PR"
        guard !labelRaw.isEmpty else {
            return "ERROR: Invalid review label — usage: report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y]"
        }
        let label = String(labelRaw.prefix(16))

        // Shell integration provides explicit workspace/panel UUIDs for browser metadata.
        // Keep this telemetry path off-main so SwiftUI render passes can't deadlock the socket handler.
        let resolution = sidebarPanelMutationTarget(
            options: parsed.options,
            missingPanelUsage: "report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y]"
        )
        guard let target = resolution.target else {
            return resolution.error ?? "ERROR: Tab not found"
        }
        sidebarContext?.controlSidebarSchedulePanelPullRequestUpdate(
            target: target,
            number: number,
            label: label,
            url: url,
            statusRawValue: statusRaw,
            branch: branch
        )
        return "OK"
    }

    /// `clear_pr` — clear a panel's pull request.
    func sidebarClearPullRequest(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        let resolution = sidebarPanelMutationTarget(
            options: parsed.options,
            missingPanelUsage: "clear_pr [--tab=X] [--panel=Y]"
        )
        guard let target = resolution.target else {
            return resolution.error ?? "ERROR: Tab not found"
        }
        sidebarContext?.controlSidebarSchedulePanelPullRequestClear(target: target)
        return "OK"
    }

    /// `report_pr_action` — record a PR command hint on a panel.
    func sidebarReportPullRequestAction(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard let rawAction = parsed.positional.first, !rawAction.isEmpty else {
            return "ERROR: Missing PR action — usage: report_pr_action <merge|close|reopen|create|checkout|ready|edit|view> [--target=X] [--tab=X] [--panel=Y]"
        }

        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validActions = Set(["merge", "close", "reopen", "create", "checkout", "ready", "edit", "view"])
        guard validActions.contains(action) else {
            return "ERROR: Invalid PR action '\(rawAction)'"
        }

        let actionTarget = sidebarNormalizedOptionValue(parsed.options["target"])
        let resolution = sidebarPanelMutationTarget(
            options: parsed.options,
            missingPanelUsage: "report_pr_action <merge|close|reopen|create|checkout|ready|edit|view> [--target=X] [--tab=X] [--panel=Y]"
        )
        guard let target = resolution.target else {
            return resolution.error ?? "ERROR: Tab not found"
        }
        sidebarContext?.controlSidebarSchedulePanelPullRequestAction(
            target: target,
            action: action,
            actionTarget: actionTarget
        )
        return "OK"
    }

    // MARK: - Ports / pwd / shell state / tty / kick

    /// Maps the shared panel-write resolution to each command's legacy error
    /// strings (the panel-argument checks run app-side after tab resolution,
    /// preserving legacy ordering and prune side effects).
    private func sidebarPanelWriteReply(
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

    /// `report_ports` — record a surface's listening ports.
    func sidebarReportPorts(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing ports — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
        }
        var ports: [Int] = []
        for portStr in parsed.positional {
            guard let port = Int(portStr), port > 0, port <= 65535 else {
                return "ERROR: Invalid port '\(portStr)' — must be 1-65535"
            }
            ports.append(port)
        }

        let resolution = sidebarContext?.controlSidebarSetPorts(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"],
            ports: ports
        ) ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
        )
    }

    /// `clear_ports` — clear a surface's (or all) listening ports.
    func sidebarClearPorts(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        let resolution = sidebarContext?.controlSidebarClearPorts(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"]
        ) ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "clear_ports [--tab=X] [--panel=Y]"
        )
    }

    /// `report_pwd` — record a surface's working directory.
    func sidebarReportPwd(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let parsed = sidebarParseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing path — usage: report_pwd <path> [--tab=X] [--panel=Y]"
        }

        let directory = parsed.positional.joined(separator: " ")
        if let scope = sidebarExplicitScope(options: parsed.options) {
            sidebarContext?.controlSidebarScheduleScopedDirectoryUpdate(scope: scope, directory: directory)
            return "OK"
        }
        let resolution = sidebarContext?.controlSidebarUpdateDirectory(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"],
            directory: directory
        ) ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "report_pwd <path> [--tab=X] [--panel=Y]"
        )
    }

    /// `report_shell_state` — record a surface's shell activity state.
    func sidebarReportShellState(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard let rawState = parsed.positional.first, !rawState.isEmpty else {
            return "ERROR: Missing shell state — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
        }
        guard let stateRawValue = context?.controlSurfaceParseShellActivityState(rawState) else {
            return "ERROR: Invalid shell state '\(rawState)' — expected prompt or running"
        }

        if let scope = sidebarExplicitScope(options: parsed.options) {
            sidebarContext?.controlSidebarScheduleScopedShellState(scope: scope, stateRawValue: stateRawValue)
            return "OK"
        }

        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        let resolution = sidebarContext?.controlSidebarUpdateShellState(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"],
            stateRawValue: stateRawValue
        ) ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
        )
    }

    /// `report_tty` — record a surface's TTY name.
    func sidebarReportTTY(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard let ttyName = parsed.positional.first, !ttyName.isEmpty else {
            return "ERROR: Missing tty name — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
        }

        if let scope = sidebarExplicitScope(options: parsed.options) {
            sidebarContext?.controlSidebarScheduleScopedTTY(scope: scope, ttyName: ttyName)
            return "OK"
        }

        let resolution = sidebarContext?.controlSidebarReportTTY(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"],
            ttyName: ttyName
        ) ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "report_tty <tty_name> [--tab=X] [--panel=Y]"
        )
    }

    /// `ports_kick` — kick the port scanner for a surface.
    func sidebarPortsKick(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        let reasonRawValue: String
        if let rawReason = parsed.options["reason"], !rawReason.isEmpty {
            guard let parsedReason = context?.controlSurfaceParsePortScanKickReason(rawReason) else {
                return "ERROR: Invalid ports_kick reason '\(rawReason)' — expected command or refresh"
            }
            reasonRawValue = parsedReason
        } else {
            reasonRawValue = "command"
        }

        if let scope = sidebarExplicitScope(options: parsed.options) {
            sidebarContext?.controlSidebarScheduleScopedPortsKick(scope: scope, reasonRawValue: reasonRawValue)
            return "OK"
        }

        let resolution = sidebarContext?.controlSidebarPortsKick(
            tabArg: parsed.options["tab"],
            panelArg: parsed.options["panel"] ?? parsed.options["surface"],
            reasonRawValue: reasonRawValue
        ) ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "ports_kick [--tab=X] [--panel=Y]"
        )
    }

    // MARK: - State / reset / right sidebar

    /// `sidebar_state` — the full sidebar context listing.
    func sidebarState(_ args: String) -> String {
        guard let snapshot = sidebarContext?.controlSidebarStateSnapshot(tabArg: sidebarParseOptions(args).options["tab"]) else {
            return "ERROR: Tab not found"
        }

        var lines: [String] = []
        lines.append("tab=\(snapshot.tabID.uuidString)")
        lines.append("color=\(snapshot.customColor ?? "none")")
        lines.append("cwd=\(snapshot.currentDirectory)")

        if let focused = snapshot.focusedPanel {
            lines.append("focused_cwd=\(focused.directory)")
            lines.append("focused_panel=\(focused.panelID.uuidString)")
        } else {
            lines.append("focused_cwd=unknown")
            lines.append("focused_panel=unknown")
        }

        if let git = snapshot.gitBranch {
            lines.append("git_branch=\(git.branch)\(git.isDirty ? " dirty" : " clean")")
        } else {
            lines.append("git_branch=none")
        }

        if let pr = snapshot.firstPullRequest {
            lines.append("pr=#\(pr.number) \(pr.statusRawValue) \(pr.urlAbsoluteString)")
            lines.append("pr_label=\(pr.label)")
        } else {
            lines.append("pr=none")
            lines.append("pr_label=none")
        }

        if snapshot.listeningPorts.isEmpty {
            lines.append("ports=none")
        } else {
            lines.append("ports=\(snapshot.listeningPorts.map(String.init).joined(separator: ","))")
        }

        if let progress = snapshot.progress {
            let label = progress.label ?? ""
            lines.append("progress=\(String(format: "%.2f", progress.value)) \(label)".trimmingCharacters(in: .whitespaces))
        } else {
            lines.append("progress=none")
        }

        lines.append("status_count=\(snapshot.statusEntries.count)")
        for entry in snapshot.statusEntries {
            lines.append("  \(sidebarMetadataLine(entry))")
        }

        lines.append("meta_block_count=\(snapshot.metadataBlocks.count)")
        for block in snapshot.metadataBlocks {
            lines.append("  \(sidebarMetadataBlockLine(block))")
        }

        lines.append("log_count=\(snapshot.logCount)")
        for entry in snapshot.recentLogEntries {
            lines.append("  [\(entry.levelRawValue)] \(entry.message)")
        }

        return lines.joined(separator: "\n")
    }

    /// `reset_sidebar` — reset the sidebar context.
    func sidebarReset(_ args: String) -> String {
        guard sidebarContext?.controlSidebarReset(tabArg: sidebarParseOptions(args).options["tab"]) ?? false else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }

    /// `right_sidebar` — parse and apply a right-sidebar remote command
    /// (parse + apply stay app-side; the state reply is encoded here with the
    /// same encoder the legacy `v2Encode` used).
    func sidebarRightSidebar(_ args: String) -> String {
        let resolution = sidebarContext?.controlSidebarApplyRightSidebarRemoteCommand(tokens: sidebarTokenizeArgs(args))
            ?? .failure(message: "ERROR: App delegate not available")
        switch resolution {
        case .ok:
            return "OK"
        case .state(let visible, let modeRawValue):
            return ControlResponseEncoder().encode(.object([
                "visible": .bool(visible),
                "mode": .string(modeRawValue),
            ]))
        case .failure(let message):
            return message
        }
    }
}
