internal import Foundation

/// The v1 sidebar metadata commands (`set_status` / `report_meta` /
/// `report_meta_block` / agent PID + lifecycle / `log` / `set_progress` and
/// their clears + listings), lifted byte-faithfully from the former
/// `TerminalController` bodies. Parsing and reply formatting run here; live
/// app reach goes through ``ControlSidebarContext``.
extension ControlCommandCoordinator {
    // MARK: - Status / metadata entries

    /// The shared `set_status`/`report_meta` upsert body.
    func sidebarUpsertMetadata(_ args: String, missingError: String) -> String {
        let parsed = sidebarParseOptionsNoStop(args)
        guard parsed.positional.count >= 2 else { return missingError }

        let key = parsed.positional[0]
        let value = parsed.positional[1...].joined(separator: " ")
        let icon = sidebarNormalizedOptionValue(parsed.options["icon"])
        let color = sidebarNormalizedOptionValue(parsed.options["color"])

        let formatRaw = sidebarNormalizedOptionValue(parsed.options["format"]) ?? ControlSidebarMetadataFormat.plain.rawValue
        guard let format = sidebarParseMetadataFormat(formatRaw) else {
            return "ERROR: Invalid metadata format '\(formatRaw)' — use: plain, markdown"
        }

        let priority: Int
        if let rawPriority = sidebarNormalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let parsedURL: URL?
        if let rawURL = sidebarNormalizedOptionValue(parsed.options["url"] ?? parsed.options["link"]) {
            guard let candidate = URL(string: rawURL),
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "ERROR: Invalid metadata URL '\(rawURL)' — expected http(s) URL"
            }
            parsedURL = candidate
        } else {
            parsedURL = nil
        }

        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(
            options: parsed.options,
            usage: "set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] [--panel=ID]"
        )
        if let error = panelResolution.error {
            return error
        }

        let pidValue: Int32? = {
            if let rawPid = sidebarNormalizedOptionValue(parsed.options["pid"]),
               let p = Int32(rawPid), p > 0 {
                return p
            }
            return nil
        }()

        sidebarContext?.controlSidebarScheduleStatusUpsert(
            target: target,
            key: key,
            value: value,
            icon: icon,
            color: color,
            url: parsedURL,
            priority: priority,
            format: format,
            panelID: panelResolution.panelId,
            pid: pidValue
        )
        return "OK"
    }

    /// The shared `clear_status`/`clear_meta` body.
    func sidebarClearMetadata(_ args: String, usage: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata key — usage: \(usage)"
        }

        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }

        sidebarContext?.controlSidebarScheduleStatusClear(
            target: target,
            key: key,
            panelID: panelResolution.panelId
        )
        return "OK"
    }

    /// `set_status` — upsert a status entry.
    func sidebarSetStatus(_ args: String) -> String {
        sidebarUpsertMetadata(
            args,
            missingError: "ERROR: Missing status key or value — usage: set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]"
        )
    }

    /// `report_meta` — upsert a metadata entry.
    func sidebarReportMeta(_ args: String) -> String {
        sidebarUpsertMetadata(
            args,
            missingError: "ERROR: Missing metadata key or value — usage: report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]"
        )
    }

    /// `clear_status` — remove a status entry.
    func sidebarClearStatus(_ args: String) -> String {
        sidebarClearMetadata(args, usage: "clear_status <key> [--tab=X]")
    }

    /// `clear_meta` — remove a metadata entry.
    func sidebarClearMeta(_ args: String) -> String {
        sidebarClearMetadata(args, usage: "clear_meta <key> [--tab=X]")
    }

    /// The shared `list_status`/`list_meta` body.
    func sidebarListMetadata(_ args: String, emptyMessage: String) -> String {
        guard let entries = sidebarContext?.controlSidebarStatusEntries(tabArg: sidebarParseOptions(args).options["tab"]) else {
            return "ERROR: Tab not found"
        }
        if entries.isEmpty {
            return emptyMessage
        }
        return entries.map(sidebarMetadataLine).joined(separator: "\n")
    }

    /// `list_status` — list status entries.
    func sidebarListStatus(_ args: String) -> String {
        sidebarListMetadata(args, emptyMessage: "No status entries")
    }

    /// `list_meta` — list metadata entries.
    func sidebarListMeta(_ args: String) -> String {
        sidebarListMetadata(args, emptyMessage: "No metadata entries")
    }

    // MARK: - Metadata blocks

    /// `report_meta_block` — upsert a markdown metadata block.
    func sidebarReportMetaBlock(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        let parts = sidebarSplitMetadataBlockArgs(args)
        let parsed = sidebarParseOptionsNoStop(parts.optionsPart)
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
        if let rawPriority = sidebarNormalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata block priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }

        sidebarContext?.controlSidebarScheduleMetadataBlockUpsert(
            target: target,
            key: key,
            markdown: normalizedMarkdown,
            priority: priority
        )
        return "OK"
    }

    /// `clear_meta_block` — remove a metadata block.
    func sidebarClearMetaBlock(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata block key — usage: clear_meta_block <key> [--tab=X]"
        }

        switch sidebarContext?.controlSidebarClearMetadataBlock(tabArg: parsed.options["tab"], key: key) ?? .tabNotFound {
        case .tabNotFound:
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        case .removed:
            return "OK"
        case .keyNotFound:
            return "OK (key not found)"
        }
    }

    /// `list_meta_blocks` — list metadata blocks.
    func sidebarListMetaBlocks(_ args: String) -> String {
        guard let blocks = sidebarContext?.controlSidebarMetadataBlocks(tabArg: sidebarParseOptions(args).options["tab"]) else {
            return "ERROR: Tab not found"
        }
        if blocks.isEmpty {
            return "No metadata blocks"
        }
        return blocks.map(sidebarMetadataBlockLine).joined(separator: "\n")
    }

    // MARK: - Agent PID / lifecycle

    /// `set_agent_pid` — register an agent PID for stale-session detection.
    func sidebarSetAgentPID(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "set_agent_pid <key> <pid> [--tab=<id>] [--panel=<id>]"
        guard parsed.positional.count >= 2,
              let pid = Int32(parsed.positional[1]), pid > 0 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        sidebarContext?.controlSidebarScheduleAgentPIDRecord(
            target: target,
            key: key,
            pid: pid,
            panelID: panelResolution.panelId
        )
        return "OK"
    }

    /// `set_agent_lifecycle` — record a restorable agent session's lifecycle.
    func sidebarSetAgentLifecycle(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>]"
        guard parsed.positional.count >= 2 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        let rawLifecycle = parsed.positional[1]
        guard let lifecycleRawValue = sidebarContext?.controlSidebarParseAgentLifecycle(rawLifecycle) else {
            return "ERROR: Invalid agent lifecycle '\(parsed.positional[1])' — usage: \(usage)"
        }
        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        guard sidebarContext?.controlSidebarIsAllowedAgentLifecycleKey(
            key,
            target: target,
            panelID: panelResolution.panelId
        ) ?? false else {
            return "ERROR: Unsupported agent lifecycle key '\(key)'"
        }
        sidebarContext?.controlSidebarScheduleAgentLifecycle(
            target: target,
            key: key,
            lifecycleRawValue: lifecycleRawValue,
            panelID: panelResolution.panelId
        )
        return "OK"
    }

    /// `agent_hibernation` — the global hibernation toggle.
    func sidebarAgentHibernation(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        let subcommand = parsed.positional.first?.lowercased()
        let usage = "agent_hibernation <on|off>"

        switch subcommand {
        case "on", "enable", "enabled", "true":
            sidebarContext?.controlSidebarSetAgentHibernation(enabled: true)
            return "OK"
        case "off", "disable", "disabled", "false":
            sidebarContext?.controlSidebarSetAgentHibernation(enabled: false)
            return "OK"
        default:
            return "ERROR: Usage: \(usage)"
        }
    }

    /// `clear_agent_pid` — unregister an agent PID.
    func sidebarClearAgentPID(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "clear_agent_pid <key> [--tab=<id>] [--panel=<id>] [--clear-status]"
        guard let key = parsed.positional.first else {
            return "ERROR: Usage: \(usage)"
        }
        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        sidebarContext?.controlSidebarScheduleAgentPIDClear(
            target: target,
            key: key,
            panelID: panelResolution.panelId,
            clearStatus: parsed.options["clear-status"] != nil
        )
        return "OK"
    }

    // MARK: - Log / progress

    /// `log` — append a sidebar log entry.
    func sidebarAppendLog(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>"
        }
        let message = parsed.positional.joined(separator: " ")
        let levelStr = parsed.options["level"] ?? "info"
        guard sidebarContext?.controlSidebarIsValidLogLevel(levelStr) ?? false else {
            return "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error"
        }
        let source = parsed.options["source"]

        guard sidebarContext?.controlSidebarAppendLog(
            tabArg: parsed.options["tab"],
            message: message,
            levelRawValue: levelStr,
            source: source
        ) ?? false else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_log` — clear the sidebar log.
    func sidebarClearLog(_ args: String) -> String {
        guard sidebarContext?.controlSidebarClearLog(tabArg: sidebarParseOptions(args).options["tab"]) ?? false else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }

    /// `list_log` — list sidebar log entries.
    func sidebarListLog(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
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

        guard let allEntries = sidebarContext?.controlSidebarLogEntries(tabArg: parsed.options["tab"]) else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        if allEntries.isEmpty {
            return "No log entries"
        }
        let entries: [ControlSidebarLogEntrySnapshot]
        if let limit {
            entries = Array(allEntries.suffix(limit))
        } else {
            entries = allEntries
        }
        return entries.map { entry in
            var line = "[\(entry.levelRawValue)] \(entry.message)"
            if let source = entry.source, !source.isEmpty {
                line = "[\(source)] \(line)"
            }
            return line
        }.joined(separator: "\n")
    }

    /// `set_progress` — set the sidebar progress bar.
    func sidebarSetProgress(_ args: String) -> String {
        let parsed = sidebarParseOptions(args)
        guard let first = parsed.positional.first else {
            return "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]"
        }
        guard let value = Double(first), value.isFinite else {
            return "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0"
        }
        let clamped = min(1.0, max(0.0, value))
        let label = parsed.options["label"]

        guard sidebarContext?.controlSidebarSetProgress(
            tabArg: parsed.options["tab"],
            value: clamped,
            label: label
        ) ?? false else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_progress` — clear the sidebar progress bar.
    func sidebarClearProgress(_ args: String) -> String {
        guard sidebarContext?.controlSidebarClearProgress(tabArg: sidebarParseOptions(args).options["tab"]) ?? false else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }
}
