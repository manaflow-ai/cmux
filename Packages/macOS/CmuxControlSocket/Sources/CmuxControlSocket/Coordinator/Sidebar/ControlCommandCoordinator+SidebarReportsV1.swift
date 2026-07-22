internal import Foundation

/// The v1 sidebar telemetry/report commands (`report_git_branch` / `report_pr`
/// / `report_ports` / `report_pwd` / `report_shell_state` / `report_tty` /
/// `ports_kick` / `sidebar_state` / `reset_sidebar` / `right_sidebar`), lifted
/// byte-faithfully from the former `TerminalController` bodies.
///
/// The report/clear/kick family is `nonisolated` (the socket dispatcher's v1
/// worker lane runs them on the connection thread): parse/validation runs on
/// the calling thread, the explicit-scope hot paths enqueue on the ordered
/// mutation bus with zero main hops, and each fallback path crosses to the
/// main actor exactly once via
/// ``ControlSidebarContext/controlSidebarOnMain(_:)`` for its synchronous
/// resolution write. `sidebar_state` / `reset_sidebar` / `right_sidebar`
/// stay on the main actor (unmigrated).
extension ControlCommandCoordinator {
    // MARK: - Git branch

    /// `report_git_branch` — record the reported git branch (scoped path:
    /// parse + bus enqueue, zero hops; fallback path: one resolution hop).
    nonisolated func sidebarReportGitBranch(_ args: String, context: (any ControlCommandContext)?) -> String {
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
            context?.controlSidebarScheduleScopedGitBranchUpdate(scope: scope, branch: branch, isDirty: isDirty)
            return "OK"
        }

        let tabArg = parsed.options["tab"]
        let updated = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarUpdateGitBranch(tabArg: tabArg, branch: branch, isDirty: isDirty)
            }
        } ?? false
        guard updated else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_git_branch` — clear the reported git branch.
    nonisolated func sidebarClearGitBranch(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)

        if let scope = sidebarExplicitScope(options: parsed.options) {
            context?.controlSidebarScheduleScopedGitBranchClear(scope: scope)
            return "OK"
        }
        let tabArg = parsed.options["tab"]
        let cleared = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarClearGitBranch(tabArg: tabArg) }
        } ?? false
        guard cleared else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }

    // MARK: - Pull requests

    /// `report_pr` / `report_review` — record a pull request on a panel
    /// (parse + bus enqueue; zero main hops, replies are parse-only).
    nonisolated func sidebarReportPullRequest(_ args: String, context: (any ControlCommandContext)?) -> String {
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
        guard context?.controlSidebarIsValidPullRequestState(statusRaw) ?? false else {
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
        context?.controlSidebarSchedulePanelPullRequestUpdate(
            target: target,
            number: number,
            label: label,
            url: url,
            statusRawValue: statusRaw,
            branch: branch
        )
        return "OK"
    }

    /// `clear_pr` — clear a panel's pull request (parse + bus enqueue).
    nonisolated func sidebarClearPullRequest(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let resolution = sidebarPanelMutationTarget(
            options: parsed.options,
            missingPanelUsage: "clear_pr [--tab=X] [--panel=Y]"
        )
        guard let target = resolution.target else {
            return resolution.error ?? "ERROR: Tab not found"
        }
        context?.controlSidebarSchedulePanelPullRequestClear(target: target)
        return "OK"
    }

    /// `report_pr_action` — record a PR command hint on a panel (parse + bus
    /// enqueue).
    nonisolated func sidebarReportPullRequestAction(_ args: String, context: (any ControlCommandContext)?) -> String {
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
        context?.controlSidebarSchedulePanelPullRequestAction(
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
    private nonisolated func sidebarPanelWriteReply(
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

    /// `report_ports` — record a surface's listening ports (port parsing
    /// off-main, one resolution hop for the synchronous write + prune).
    nonisolated func sidebarReportPorts(_ args: String, context: (any ControlCommandContext)?) -> String {
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

        let tabArg = parsed.options["tab"]
        let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
        let resolution = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarSetPorts(tabArg: tabArg, panelArg: panelArg, ports: ports)
            }
        } ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
        )
    }

    /// `clear_ports` — clear a surface's (or all) listening ports (one
    /// resolution hop).
    nonisolated func sidebarClearPorts(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let tabArg = parsed.options["tab"]
        let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
        let resolution = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarClearPorts(tabArg: tabArg, panelArg: panelArg)
            }
        } ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "clear_ports [--tab=X] [--panel=Y]"
        )
    }

    /// `report_pwd` — record a surface's working directory. The positional
    /// argument is the real path unless `--path=` supplies one, in which case
    /// the positional becomes a display-only sidebar label.
    ///
    /// The legacy body checks TabManager availability BEFORE any parse error,
    /// so the reply is selected inside this command's single hop, over parse
    /// results precomputed on the calling thread, in that exact order. The
    /// explicit-scope enqueue also runs inside the hop (an enqueue from the
    /// main actor, exactly as the legacy main-lane body did), keeping the
    /// whole command to one hop instead of an availability hop plus a write
    /// hop.
    nonisolated func sidebarReportPwd(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)

        // Precomputed parse (legacy order preserved below): positional check,
        // then the explicit `--path=` reconciliation.
        let missingPathError = "ERROR: Missing path — usage: report_pwd <path|display-label> [--path=/actual/path] [--tab=X] [--panel=Y]"
        let missingFilesystemPathError = "ERROR: Missing filesystem path — usage: report_pwd <display-label> --path=/actual/path [--tab=X] [--panel=Y]"
        let positional = parsed.positional.joined(separator: " ")
        let explicitPath = parsed.options["path"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parseError: String?
        if parsed.positional.isEmpty {
            parseError = missingPathError
        } else if let explicitPath, explicitPath.isEmpty {
            parseError = missingFilesystemPathError
        } else {
            parseError = nil
        }
        let directory = explicitPath ?? positional
        let displayLabel = explicitPath == nil ? nil : positional
        let scope = sidebarExplicitScope(options: parsed.options)
        let tabArg = parsed.options["tab"]
        let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
        let hasTabOption = parsed.options["tab"] != nil

        guard let context else { return "ERROR: TabManager not available" }
        return context.controlSidebarOnMain { seam in
            guard seam.controlSidebarTabManagerAvailable() else {
                return "ERROR: TabManager not available"
            }
            if let parseError {
                return parseError
            }
            if let scope {
                seam.controlSidebarScheduleScopedDirectoryUpdate(
                    scope: scope,
                    directory: directory,
                    displayLabel: displayLabel
                )
                return "OK"
            }
            return self.sidebarPanelWriteReply(
                seam.controlSidebarUpdateDirectory(
                    tabArg: tabArg,
                    panelArg: panelArg,
                    directory: directory,
                    displayLabel: displayLabel
                ),
                hasTabOption: hasTabOption,
                missingPanelUsage: "report_pwd <path|display-label> [--path=/actual/path] [--tab=X] [--panel=Y]"
            )
        }
    }

    /// `report_shell_state` — record a surface's shell activity state. The
    /// explicit-scope hot path (every shell prompt/command) is parse + dedupe
    /// + bus enqueue with zero main hops; the fallback path folds the legacy
    /// TabManager-availability guard and the synchronous write into one hop,
    /// in the legacy order.
    nonisolated func sidebarReportShellState(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        guard let rawState = parsed.positional.first, !rawState.isEmpty else {
            return "ERROR: Missing shell state — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
        }
        guard let stateRawValue = context?.controlSurfaceParseShellActivityState(rawState) else {
            return "ERROR: Invalid shell state '\(rawState)' — expected prompt or running"
        }

        if let scope = sidebarExplicitScope(options: parsed.options) {
            context?.controlSidebarScheduleScopedShellState(scope: scope, stateRawValue: stateRawValue)
            return "OK"
        }

        let tabArg = parsed.options["tab"]
        let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
        let hasTabOption = parsed.options["tab"] != nil
        guard let context else { return "ERROR: TabManager not available" }
        return context.controlSidebarOnMain { seam in
            guard seam.controlSidebarTabManagerAvailable() else {
                return "ERROR: TabManager not available"
            }
            return self.sidebarPanelWriteReply(
                seam.controlSidebarUpdateShellState(
                    tabArg: tabArg,
                    panelArg: panelArg,
                    stateRawValue: stateRawValue
                ),
                hasTabOption: hasTabOption,
                missingPanelUsage: "report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
            )
        }
    }

    /// `report_tty` — record a surface's TTY name. The explicit-scope path
    /// enqueues on the ordered mutation bus (zero hops) — the same bus the
    /// scoped `ports_kick` uses, so a kick enqueued after a TTY report drains
    /// after the registration, preserving the report-then-kick dependency.
    /// The fallback path (e.g. tmux, which omits `--panel`) keeps its
    /// synchronous registration inside one hop so the reply is written only
    /// after the registration is visible.
    nonisolated func sidebarReportTTY(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        guard let ttyName = parsed.positional.first, !ttyName.isEmpty else {
            return "ERROR: Missing tty name — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
        }

        if let scope = sidebarExplicitScope(options: parsed.options) {
            context?.controlSidebarScheduleScopedTTY(scope: scope, ttyName: ttyName)
            return "OK"
        }

        let tabArg = parsed.options["tab"]
        let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
        let resolution = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarReportTTY(tabArg: tabArg, panelArg: panelArg, ttyName: ttyName)
            }
        } ?? .tabNotFound
        return sidebarPanelWriteReply(
            resolution,
            hasTabOption: parsed.options["tab"] != nil,
            missingPanelUsage: "report_tty <tty_name> [--tab=X] [--panel=Y]"
        )
    }

    /// `ports_kick` — kick the port scanner for a surface (scoped path:
    /// reason parse + bus enqueue, zero hops; fallback: one resolution hop).
    nonisolated func sidebarPortsKick(_ args: String, context: (any ControlCommandContext)?) -> String {
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
            context?.controlSidebarScheduleScopedPortsKick(scope: scope, reasonRawValue: reasonRawValue)
            return "OK"
        }

        let tabArg = parsed.options["tab"]
        let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
        let resolution = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarPortsKick(tabArg: tabArg, panelArg: panelArg, reasonRawValue: reasonRawValue)
            }
        } ?? .tabNotFound
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
