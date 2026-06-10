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


// MARK: - Sidebar metadata, agent lifecycle, and log commands
extension TerminalController {
    private func upsertSidebarMetadata(_ args: String, missingError: String) -> String {
        let parsed = parseOptionsNoStop(args)
        guard parsed.positional.count >= 2 else { return missingError }

        let key = parsed.positional[0]
        let value = parsed.positional[1...].joined(separator: " ")
        let icon = normalizedOptionValue(parsed.options["icon"])
        let color = normalizedOptionValue(parsed.options["color"])

        let formatRaw = normalizedOptionValue(parsed.options["format"]) ?? SidebarMetadataFormat.plain.rawValue
        guard let format = parseSidebarMetadataFormat(formatRaw) else {
            return "ERROR: Invalid metadata format '\(formatRaw)' — use: plain, markdown"
        }

        let priority: Int
        if let rawPriority = normalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let parsedURL: URL?
        if let rawURL = normalizedOptionValue(parsed.options["url"] ?? parsed.options["link"]) {
            guard let candidate = URL(string: rawURL),
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "ERROR: Invalid metadata URL '\(rawURL)' — expected http(s) URL"
            }
            parsedURL = candidate
        } else {
            parsedURL = nil
        }

        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = parseOptionalPanelIdOption(
            options: parsed.options,
            usage: "set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] [--panel=ID]"
        )
        if let error = panelResolution.error {
            return error
        }

        let pidValue: pid_t? = {
            if let rawPid = normalizedOptionValue(parsed.options["pid"]),
               let p = Int32(rawPid), p > 0 {
                return p
            }
            return nil
        }()

        scheduleSidebarMutation(target: target) { _, tab in
            if let panelId = panelResolution.panelId, !tab.panels.keys.contains(panelId) {
                return
            }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format
            ) else {
                // Still update PID tracking even if the status display hasn't changed.
                if let pidValue {
                    tab.recordAgentPID(key: key, pid: pidValue, panelId: panelResolution.panelId)
                }
                return
            }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format,
                timestamp: Date()
            )
            if let pidValue {
                tab.recordAgentPID(key: key, pid: pidValue, panelId: panelResolution.panelId)
            }
        }
        return "OK"
    }

    private func clearSidebarMetadata(_ args: String, usage: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata key — usage: \(usage)"
        }

        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }

        scheduleSidebarMutation(target: target) { _, tab in
            _ = tab.statusEntries.removeValue(forKey: key)
            tab.clearAgentPID(key: key)
        }
        return "OK"
    }

    /// Register an agent PID for stale-session detection without setting a visible status entry.
    /// Usage: set_agent_pid <key> <pid> [--tab=<id>] [--panel=<id>]
    func setAgentPID(_ args: String) -> String {
        let parsed = parseOptions(args)
        let usage = "set_agent_pid <key> <pid> [--tab=<id>] [--panel=<id>]"
        guard parsed.positional.count >= 2,
              let pid = Int32(parsed.positional[1]), pid > 0 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = parseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        scheduleSidebarMutation(target: target) { _, tab in
            if let panelId = panelResolution.panelId, !tab.panels.keys.contains(panelId) {
                return
            }
            let didReplaceAgentRuntime = tab.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelResolution.panelId
            )
            if didReplaceAgentRuntime, let panelId = panelResolution.panelId {
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tab.id,
                    surfaceId: panelId,
                    discardQueuedNotifications: false
                )
            }
        }
        return "OK"
    }

    /// Record the lifecycle state of a restorable agent session.
    /// Usage: set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>]
    func setAgentLifecycle(_ args: String) -> String {
        let parsed = parseOptions(args)
        let usage = "set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>]"
        guard parsed.positional.count >= 2 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        let rawLifecycle = parsed.positional[1]
        guard let lifecycle = AgentHibernationLifecycleState.parseCLIValue(rawLifecycle) else {
            return "ERROR: Invalid agent lifecycle '\(parsed.positional[1])' — usage: \(usage)"
        }
        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = parseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        guard isAllowedAgentLifecycleKey(
            key,
            target: target,
            panelId: panelResolution.panelId
        ) else {
            return "ERROR: Unsupported agent lifecycle key '\(key)'"
        }
        scheduleSidebarMutation(target: target) { _, tab in
            if let panelId = panelResolution.panelId, !tab.panels.keys.contains(panelId) {
                return
            }
            tab.setAgentLifecycle(key: key, panelId: panelResolution.panelId, lifecycle: lifecycle)
        }
        return "OK"
    }

    private func isAllowedAgentLifecycleKey(
        _ key: String,
        target: SidebarMutationTabTarget,
        panelId: UUID?
    ) -> Bool {
        if AgentHibernationLifecycleStatusKeys.isAllowed(key) {
            return true
        }
        guard let tab = resolveSidebarMutationTab(target),
              CmuxVaultAgentRegistration.isValidID(key) else {
            return false
        }
        let registry = CmuxVaultAgentRegistry.load(
            workingDirectory: agentLifecycleRegistryWorkingDirectory(tab: tab, panelId: panelId)
        )
        return registry.registration(id: key) != nil
    }

    private func agentLifecycleRegistryWorkingDirectory(tab: Tab, panelId: UUID?) -> String? {
        let candidates = [
            panelId.flatMap { tab.panelDirectories[$0] },
            tab.focusedPanelId.flatMap { tab.panelDirectories[$0] },
            tab.currentDirectory,
        ]
        return candidates.compactMap(normalizedOptionValue).first
    }

    func agentHibernation(_ args: String) -> String {
        let parsed = parseOptions(args)
        let subcommand = parsed.positional.first?.lowercased()
        let usage = "agent_hibernation <on|off>"

        switch subcommand {
        case "on", "enable", "enabled", "true":
            AgentHibernationSettings.setValues(enabled: true)
            return "OK"
        case "off", "disable", "disabled", "false":
            AgentHibernationSettings.setValues(enabled: false)
            return "OK"
        default:
            return "ERROR: Usage: \(usage)"
        }
    }

    /// Unregister an agent PID. Usage: clear_agent_pid <key> [--tab=<id>] [--panel=<id>] [--clear-status]
    func clearAgentPID(_ args: String) -> String {
        let parsed = parseOptions(args)
        let usage = "clear_agent_pid <key> [--tab=<id>] [--panel=<id>] [--clear-status]"
        guard let key = parsed.positional.first else {
            return "ERROR: Usage: \(usage)"
        }
        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = parseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        scheduleSidebarMutation(target: target) { _, tab in
            if let panelId = panelResolution.panelId, !tab.panels.keys.contains(panelId) {
                return
            }
            tab.clearAgentPID(
                key: key,
                panelId: panelResolution.panelId,
                clearStatus: parsed.options["clear-status"] != nil
            )
        }
        return "OK"
    }

    func sidebarMetadataLine(_ entry: SidebarStatusEntry) -> String {
        var line = "\(entry.key)=\(entry.value)"
        if let icon = entry.icon { line += " icon=\(icon)" }
        if let color = entry.color { line += " color=\(color)" }
        if let url = entry.url { line += " url=\(url.absoluteString)" }
        if entry.priority != 0 { line += " priority=\(entry.priority)" }
        if entry.format != .plain { line += " format=\(entry.format.rawValue)" }
        return line
    }

    private func listSidebarMetadata(_ args: String, emptyMessage: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            let entries = tab.sidebarStatusEntriesInDisplayOrder()
            if entries.isEmpty {
                result = emptyMessage
                return
            }
            result = entries.map(sidebarMetadataLine).joined(separator: "\n")
        }
        return result
    }

    func setStatus(_ args: String) -> String {
        upsertSidebarMetadata(
            args,
            missingError: "ERROR: Missing status key or value — usage: set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]"
        )
    }

    func reportMeta(_ args: String) -> String {
        upsertSidebarMetadata(
            args,
            missingError: "ERROR: Missing metadata key or value — usage: report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]"
        )
    }

    func clearStatus(_ args: String) -> String {
        clearSidebarMetadata(args, usage: "clear_status <key> [--tab=X]")
    }

    func clearMeta(_ args: String) -> String {
        clearSidebarMetadata(args, usage: "clear_meta <key> [--tab=X]")
    }

    func listStatus(_ args: String) -> String {
        listSidebarMetadata(args, emptyMessage: "No status entries")
    }

    func listMeta(_ args: String) -> String {
        listSidebarMetadata(args, emptyMessage: "No metadata entries")
    }

    private func splitMetadataBlockArgs(_ args: String) -> (optionsPart: String, markdownPart: String?) {
        guard let separatorRange = args.range(of: " -- ") else {
            return (args, nil)
        }
        let optionsPart = String(args[..<separatorRange.lowerBound])
        let markdownPart = String(args[separatorRange.upperBound...])
        return (optionsPart, markdownPart)
    }

    func sidebarMetadataBlockLine(_ block: SidebarMetadataBlock) -> String {
        var line = "\(block.key)=\(block.markdown.replacingOccurrences(of: "\n", with: "\\n"))"
        if block.priority != 0 { line += " priority=\(block.priority)" }
        return line
    }

    func reportMetaBlock(_ args: String) -> String {
        guard tabManager != nil else { return "ERROR: TabManager not available" }

        let parts = splitMetadataBlockArgs(args)
        let parsed = parseOptionsNoStop(parts.optionsPart)
        guard let key = parsed.positional.first, !key.isEmpty else {
            return "ERROR: Missing metadata block key — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>"
        }

        let markdown: String
        if let raw = parts.markdownPart {
            markdown = raw
        } else if parsed.positional.count >= 2 {
            markdown = parsed.positional.dropFirst().joined(separator: " ")
        } else {
            return "ERROR: Missing metadata markdown — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>"
        }

        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        let trimmedMarkdown = normalizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMarkdown.isEmpty else {
            return "ERROR: Missing metadata markdown — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>"
        }

        let priority: Int
        if let rawPriority = normalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata block priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }

        scheduleSidebarMutation(target: target) { _, tab in
            guard Self.shouldReplaceMetadataBlock(
                current: tab.metadataBlocks[key],
                key: key,
                markdown: normalizedMarkdown,
                priority: priority
            ) else {
                return
            }
            tab.metadataBlocks[key] = SidebarMetadataBlock(
                key: key,
                markdown: normalizedMarkdown,
                priority: priority,
                timestamp: Date()
            )
        }
        return "OK"
    }

    func clearMetaBlock(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata block key — usage: clear_meta_block <key> [--tab=X]"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.metadataBlocks.removeValue(forKey: key) == nil {
                result = "OK (key not found)"
            }
        }
        return result
    }

    func listMetaBlocks(_ args: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            let blocks = tab.sidebarMetadataBlocksInDisplayOrder()
            if blocks.isEmpty {
                result = "No metadata blocks"
                return
            }
            result = blocks.map(sidebarMetadataBlockLine).joined(separator: "\n")
        }
        return result
    }

    func appendLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>"
        }
        let message = parsed.positional.joined(separator: " ")
        let levelStr = parsed.options["level"] ?? "info"
        guard let level = SidebarLogLevel(rawValue: levelStr) else {
            return "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error"
        }
        let source = parsed.options["source"]

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
            let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
            let limit = max(1, min(500, configuredLimit))
            if tab.logEntries.count > limit {
                tab.logEntries.removeFirst(tab.logEntries.count - limit)
            }
        }
        return result
    }

    func clearLog(_ args: String) -> String {
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.logEntries.removeAll()
        }
        return result
    }

    func listLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        var limit: Int?
        if let limitStr = parsed.options["limit"] {
            if limitStr.isEmpty {
                return "ERROR: Missing limit value — usage: list_log [--limit=N] [--tab=X]"
            }
            guard let parsedLimit = Int(limitStr), parsedLimit >= 0 else {
                return "ERROR: Invalid limit '\(limitStr)' — must be >= 0"
            }
            limit = parsedLimit
        }

        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.logEntries.isEmpty {
                result = "No log entries"
                return
            }
            let entries: [SidebarLogEntry]
            if let limit {
                entries = Array(tab.logEntries.suffix(limit))
            } else {
                entries = tab.logEntries
            }
            result = entries.map { entry in
                var line = "[\(entry.level.rawValue)] \(entry.message)"
                if let source = entry.source, !source.isEmpty {
                    line = "[\(source)] \(line)"
                }
                return line
            }.joined(separator: "\n")
        }
        return result
    }

}
