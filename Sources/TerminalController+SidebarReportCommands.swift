import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - Sidebar report commands and status replacement heuristics
extension TerminalController {
    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    nonisolated static func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.isStale
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    nonisolated static func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }

    nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func normalizedMobileVTExportText(_ text: String) -> String {
        // Ghostty's VT formatter writes row separators as CRLF. Swift treats
        // CRLF as one Character, so split(separator: "\n") would miss rows.
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    nonisolated static func parseReportedShellActivityState(
        _ rawState: String
    ) -> Workspace.PanelShellActivityState? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt", "idle":
            return .promptIdle
        case "running", "busy", "command":
            return .commandRunning
        case "unknown", "clear":
            return .unknown
        default:
            return nil
        }
    }

    nonisolated static func parseRemotePortScanKickReason(
        _ rawReason: String
    ) -> WorkspaceRemoteSessionController.PortScanKickReason? {
        switch rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "running", "foreground", "start":
            return .command
        case "refresh", "prompt", "idle":
            return .refresh
        default:
            return nil
        }
    }

    func setProgress(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let first = parsed.positional.first else {
            return "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]"
        }
        guard let value = Double(first), value.isFinite else {
            return "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0"
        }
        let clamped = min(1.0, max(0.0, value))
        let label = parsed.options["label"]

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            tab.progress = SidebarProgressState(value: clamped, label: label)
        }
        return result
    }

    func clearProgress(_ args: String) -> String {
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.progress = nil
        }
        return result
    }

    func reportGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)
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
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            TerminalMutationBus.shared.enqueueMainActorMutation {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                guard SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard) else {
                    tabManager.clearSurfaceGitBranch(tabId: scope.workspaceId, surfaceId: scope.panelId)
                    return
                }
                tabManager.updateSurfaceGitBranch(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId,
                    branch: branch,
                    isDirty: isDirty
                )
            }
            return "OK"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            guard SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard) else {
                tab.gitBranch = nil
                return
            }
            let existingGitBranch = tab.gitBranch
            let nextIsDirty = isDirty ?? (existingGitBranch?.branch == branch ? existingGitBranch?.isDirty ?? false : false)
            tab.gitBranch = SidebarGitBranchState(
                branch: branch,
                isDirty: nextIsDirty
            )
        }
        return result
    }

    func clearGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)

        // Shell integration always includes explicit workspace/panel IDs.
        // Keep this telemetry path off-main so wake/main-thread stalls don't
        // block socket handlers and starve subsequent branch updates.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            TerminalMutationBus.shared.enqueueMainActorMutation {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.clearSurfaceGitBranch(tabId: scope.workspaceId, surfaceId: scope.panelId)
            }
            return "OK"
        }
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.gitBranch = nil
        }
        return result
    }

    func reportPullRequest(_ args: String) -> String {
        let parsed = parseOptions(args)
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
        guard let status = SidebarPullRequestStatus(rawValue: statusRaw) else {
            return "ERROR: Invalid pull request state '\(statusRaw)' — use: open, merged, closed"
        }
        let branch = normalizedOptionValue(parsed.options["branch"])
        if normalizedOptionValue(parsed.options["checks"]) != nil {
            return "ERROR: Unsupported option '--checks' — pull request checks are no longer tracked"
        }

        let labelRaw = normalizedOptionValue(parsed.options["label"]) ?? "PR"
        guard !labelRaw.isEmpty else {
            return "ERROR: Invalid review label — usage: report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y]"
        }
        let label = String(labelRaw.prefix(16))

        // Shell integration provides explicit workspace/panel UUIDs for browser metadata.
        // Keep this telemetry path off-main so SwiftUI render passes can't deadlock the socket handler.
        return schedulePanelMetadataMutation(
            args: args,
            options: parsed.options,
            missingPanelUsage: "report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y]"
        ) { tab, surfaceId in
            guard SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard) else {
                tab.clearPanelPullRequest(panelId: surfaceId)
                return
            }

            guard Self.shouldReplacePullRequest(
                current: tab.panelPullRequests[surfaceId],
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch
            ) else {
                return
            }

            tab.updatePanelPullRequest(
                panelId: surfaceId,
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch
            )
        }
    }

    func clearPullRequest(_ args: String) -> String {
        let parsed = parseOptions(args)
        return schedulePanelMetadataMutation(
            args: args,
            options: parsed.options,
            missingPanelUsage: "clear_pr [--tab=X] [--panel=Y]"
        ) { tab, surfaceId in
            tab.clearPanelPullRequest(panelId: surfaceId)
        }
    }

    func reportPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
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

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tab.surfaceListeningPorts[surfaceId] = ports
            tab.recomputeListeningPorts()
        }
        return result
    }

    func reportPwd(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing path — usage: report_pwd <path> [--tab=X] [--panel=Y]"
        }

        let directory = parsed.positional.joined(separator: " ")
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            TerminalMutationBus.shared.enqueueMainActorMutation {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.updateSurfaceDirectory(tabId: scope.workspaceId, surfaceId: scope.panelId, directory: directory)
            }
            return "OK"
        }
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_pwd <path> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tabManager.updateSurfaceDirectory(tabId: tab.id, surfaceId: surfaceId, directory: directory)
        }
        return result
    }

    func reportShellState(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let rawState = parsed.positional.first, !rawState.isEmpty else {
            return "ERROR: Missing shell state — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
        }
        guard let state = Self.parseReportedShellActivityState(rawState) else {
            return "ERROR: Invalid shell state '\(rawState)' — expected prompt or running"
        }

        if let scope = Self.explicitSocketScope(options: parsed.options) {
            guard socketFastPathState.shouldPublishShellActivity(
                workspaceId: scope.workspaceId,
                panelId: scope.panelId,
                state: state.rawValue
            ) else {
                return "OK"
            }
            TerminalMutationBus.shared.enqueueMainActorMutation {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId) else { return }
                tabManager.updateSurfaceShellActivity(tabId: scope.workspaceId, surfaceId: scope.panelId, state: state)
            }
            return "OK"
        }

        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: surfaceId, state: state)
        }
        return result
    }

    func reportPullRequestAction(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let rawAction = parsed.positional.first, !rawAction.isEmpty else {
            return "ERROR: Missing PR action — usage: report_pr_action <merge|close|reopen|create|checkout|ready|edit|view> [--target=X] [--tab=X] [--panel=Y]"
        }

        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validActions = Set(["merge", "close", "reopen", "create", "checkout", "ready", "edit", "view"])
        guard validActions.contains(action) else {
            return "ERROR: Invalid PR action '\(rawAction)'"
        }

        let target = normalizedOptionValue(parsed.options["target"])
        return schedulePanelMetadataMutation(
            args: args,
            options: parsed.options,
            missingPanelUsage: "report_pr_action <merge|close|reopen|create|checkout|ready|edit|view> [--target=X] [--tab=X] [--panel=Y]"
        ) { tab, surfaceId in
            guard SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard) else {
                tab.clearPanelPullRequest(panelId: surfaceId)
                return
            }

            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tab.id) else { return }
            tabManager.handleWorkspacePullRequestCommandHint(
                tabId: tab.id,
                surfaceId: surfaceId,
                action: action,
                target: target
            )
        }
    }

    func clearPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: clear_ports [--tab=X] [--panel=Y]"
                    return
                }
                guard let surfaceId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                guard validSurfaceIds.contains(surfaceId) else {
                    result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                    return
                }
                tab.surfaceListeningPorts.removeValue(forKey: surfaceId)
            } else {
                tab.surfaceListeningPorts.removeAll()
            }
            tab.recomputeListeningPorts()
        }
        return result
    }

    func reportTTY(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let ttyName = parsed.positional.first, !ttyName.isEmpty else {
            return "ERROR: Missing tty name — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
        }

        if let scope = Self.explicitSocketScope(options: parsed.options) {
            TerminalMutationBus.shared.enqueueMainActorMutation {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tab.surfaceTTYNames[scope.panelId] = ttyName
                if tab.isRemoteWorkspace {
                    tab.syncRemotePortScanTTYs()
                    _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: scope.panelId)
                } else {
                    PortScanner.shared.registerTTY(workspaceId: scope.workspaceId, panelId: scope.panelId, ttyName: ttyName)
                }
            }
            return "OK"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            let validSurfaceIds = Set(tab.panels.keys)
            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tab.surfaceTTYNames[surfaceId] = ttyName
            if tab.isRemoteWorkspace {
                tab.syncRemotePortScanTTYs()
                _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: surfaceId)
            } else {
                PortScanner.shared.registerTTY(workspaceId: tab.id, panelId: surfaceId, ttyName: ttyName)
            }
        }
        return result
    }

    func portsKick(_ args: String) -> String {
        let parsed = parseOptions(args)
        let reason: WorkspaceRemoteSessionController.PortScanKickReason
        if let rawReason = parsed.options["reason"], !rawReason.isEmpty {
            guard let parsedReason = Self.parseRemotePortScanKickReason(rawReason) else {
                return "ERROR: Invalid ports_kick reason '\(rawReason)' — expected command or refresh"
            }
            reason = parsedReason
        } else {
            reason = .command
        }

        if let scope = Self.explicitSocketScope(options: parsed.options) {
            TerminalMutationBus.shared.enqueueMainActorMutation {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                if tab.isRemoteWorkspace {
                    tab.kickRemotePortScan(panelId: scope.panelId, reason: reason)
                } else {
                    PortScanner.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
                }
            }
            return "OK"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: ports_kick [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            if tab.isRemoteWorkspace {
                tab.kickRemotePortScan(panelId: surfaceId, reason: reason)
            } else {
                PortScanner.shared.kick(workspaceId: tab.id, panelId: surfaceId)
            }
        }
        return result
    }

}
