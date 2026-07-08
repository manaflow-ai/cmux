internal import Foundation

/// The v1 sidebar metadata commands (`set_status` / `report_meta` /
/// `report_meta_block` / agent PID + lifecycle / `log` / `set_progress` and
/// their clears + listings), lifted byte-faithfully from the former
/// `TerminalController` bodies. Parsing and reply formatting run here; live
/// app reach goes through ``ControlSidebarContext``.
///
/// Every body is `nonisolated` (the socket dispatcher's v1 worker lane runs
/// them on the connection thread): parse/validation/formatting run on the
/// calling thread, deferred mutations go through the `nonisolated`
/// `Schedule*` seam witnesses (mutation-bus enqueues), and each command
/// crosses to the main actor at most once via
/// ``ControlSidebarContext/controlSidebarOnMain(_:)`` for its synchronous
/// resolution read/write. The seam is threaded as a parameter because the
/// coordinator's `context` property is main-actor-isolated.
extension ControlCommandCoordinator {
    // MARK: - Status / metadata entries

    /// The shared `set_status`/`report_meta` upsert body: parse + validate on
    /// the calling thread, then a bus enqueue; the `OK` reply is parse-only
    /// (zero main hops, exactly the legacy deferred-mutation semantics).
    nonisolated func sidebarUpsertMetadata(
        _ args: String,
        usage: String,
        missingError: String,
        context: (any ControlCommandContext)?
    ) -> String {
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
            usage: usage
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

        context?.controlSidebarScheduleStatusUpsert(
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

    /// The shared `clear_status`/`clear_meta` body (parse + bus enqueue; zero
    /// main hops).
    nonisolated func sidebarClearMetadata(
        _ args: String,
        usage: String,
        context: (any ControlCommandContext)?
    ) -> String {
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

        context?.controlSidebarScheduleStatusClear(
            target: target,
            key: key,
            panelID: panelResolution.panelId
        )
        return "OK"
    }

    /// `set_status` — upsert a status entry.
    nonisolated func sidebarSetStatus(_ args: String, context: (any ControlCommandContext)?) -> String {
        let usage = "set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] [--panel=ID]"
        return sidebarUpsertMetadata(
            args,
            usage: usage,
            missingError: "ERROR: Missing status key or value — usage: \(usage)",
            context: context
        )
    }

    /// `report_meta` — upsert a metadata entry.
    nonisolated func sidebarReportMeta(_ args: String, context: (any ControlCommandContext)?) -> String {
        let usage = "report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] [--panel=ID]"
        return sidebarUpsertMetadata(
            args,
            usage: usage,
            missingError: "ERROR: Missing metadata key or value — usage: \(usage)",
            context: context
        )
    }

    /// `clear_status` — remove a status entry.
    nonisolated func sidebarClearStatus(_ args: String, context: (any ControlCommandContext)?) -> String {
        sidebarClearMetadata(args, usage: "clear_status <key> [--tab=X] [--panel=ID]", context: context)
    }

    /// `clear_meta` — remove a metadata entry.
    nonisolated func sidebarClearMeta(_ args: String, context: (any ControlCommandContext)?) -> String {
        sidebarClearMetadata(args, usage: "clear_meta <key> [--tab=X] [--panel=ID]", context: context)
    }

    /// The shared `list_status`/`list_meta` body: one main hop returns the
    /// Sendable snapshots; line formatting runs on the calling thread.
    nonisolated func sidebarListMetadata(
        _ args: String,
        emptyMessage: String,
        context: (any ControlCommandContext)?
    ) -> String {
        let tabArg = sidebarParseOptions(args).options["tab"]
        let snapshot = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarStatusEntries(tabArg: tabArg) }
        } ?? nil
        guard let entries = snapshot else {
            return "ERROR: Tab not found"
        }
        if entries.isEmpty {
            return emptyMessage
        }
        return entries.map(sidebarMetadataLine).joined(separator: "\n")
    }

    /// `list_status` — list status entries.
    nonisolated func sidebarListStatus(_ args: String, context: (any ControlCommandContext)?) -> String {
        sidebarListMetadata(args, emptyMessage: "No status entries", context: context)
    }

    /// `list_meta` — list metadata entries.
    nonisolated func sidebarListMeta(_ args: String, context: (any ControlCommandContext)?) -> String {
        sidebarListMetadata(args, emptyMessage: "No metadata entries", context: context)
    }

    // MARK: - Metadata blocks

    /// The parse outcome of `report_meta_block`, computed off-main so the
    /// single hop only selects the reply in the legacy error order.
    private struct SidebarMetaBlockParse {
        let error: String?
        let key: String
        let markdown: String
        let priority: Int
        let target: ControlSidebarTabTarget

        static func failure(_ error: String) -> SidebarMetaBlockParse {
            SidebarMetaBlockParse(error: error, key: "", markdown: "", priority: 0, target: .selected)
        }
    }

    /// The byte-faithful parse head of `report_meta_block` (everything the
    /// legacy body checked after its TabManager-availability guard, in the
    /// same order).
    private nonisolated func sidebarParseReportMetaBlock(_ args: String) -> SidebarMetaBlockParse {
        let parts = sidebarSplitMetadataBlockArgs(args)
        let parsed = sidebarParseOptionsNoStop(parts.optionsPart)
        guard let key = parsed.positional.first, !key.isEmpty else {
            return .failure("ERROR: Missing metadata block key — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>")
        }

        let markdown: String
        if let raw = parts.markdownPart {
            markdown = raw
        } else if parsed.positional.count >= 2 {
            markdown = parsed.positional.dropFirst().joined(separator: " ")
        } else {
            return .failure("ERROR: Missing metadata markdown — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>")
        }

        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        let trimmedMarkdown = normalizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMarkdown.isEmpty else {
            return .failure("ERROR: Missing metadata markdown — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>")
        }

        let priority: Int
        if let rawPriority = sidebarNormalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return .failure("ERROR: Invalid metadata block priority '\(rawPriority)' — must be an integer")
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return .failure(targetResolution.error ?? "ERROR: No tab selected")
        }

        return SidebarMetaBlockParse(
            error: nil,
            key: key,
            markdown: normalizedMarkdown,
            priority: priority,
            target: target
        )
    }

    /// `report_meta_block` — upsert a markdown metadata block.
    ///
    /// The legacy body checks TabManager availability BEFORE any parse error,
    /// so the reply is selected inside the single hop, over the precomputed
    /// parse outcome, in that exact order (a request with a nil TabManager and
    /// a parse error must still report "TabManager not available").
    nonisolated func sidebarReportMetaBlock(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parse = sidebarParseReportMetaBlock(args)
        guard let context else { return "ERROR: TabManager not available" }
        return context.controlSidebarOnMain { seam in
            guard seam.controlSidebarTabManagerAvailable() else {
                return "ERROR: TabManager not available"
            }
            if let error = parse.error {
                return error
            }
            seam.controlSidebarScheduleMetadataBlockUpsert(
                target: parse.target,
                key: parse.key,
                markdown: parse.markdown,
                priority: parse.priority
            )
            return "OK"
        }
    }

    /// `clear_meta_block` — remove a metadata block. The removed-vs-key-not-
    /// found reply distinction requires the synchronous resolution, so the
    /// removal stays a single main hop.
    nonisolated func sidebarClearMetaBlock(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata block key — usage: clear_meta_block <key> [--tab=X]"
        }

        let tabArg = parsed.options["tab"]
        let resolution = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarClearMetadataBlock(tabArg: tabArg, key: key) }
        } ?? .tabNotFound
        switch resolution {
        case .tabNotFound:
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        case .removed:
            return "OK"
        case .keyNotFound:
            return "OK (key not found)"
        }
    }

    /// `list_meta_blocks` — list metadata blocks (one snapshot hop, format
    /// off-main).
    nonisolated func sidebarListMetaBlocks(_ args: String, context: (any ControlCommandContext)?) -> String {
        let tabArg = sidebarParseOptions(args).options["tab"]
        let snapshot = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarMetadataBlocks(tabArg: tabArg) }
        } ?? nil
        guard let blocks = snapshot else {
            return "ERROR: Tab not found"
        }
        if blocks.isEmpty {
            return "No metadata blocks"
        }
        return blocks.map(sidebarMetadataBlockLine).joined(separator: "\n")
    }

    // MARK: - Agent PID / lifecycle

    /// `set_agent_pid` — register an agent PID for stale-session detection
    /// (parse + bus enqueue; zero main hops).
    nonisolated func sidebarSetAgentPID(_ args: String, context: (any ControlCommandContext)?) -> String {
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
        context?.controlSidebarScheduleAgentPIDRecord(
            target: target,
            key: key,
            pid: pid,
            panelID: panelResolution.panelId
        )
        return "OK"
    }

    /// `set_agent_lifecycle` — record a restorable agent session's lifecycle.
    /// The vault-registry allowlist check
    /// (`controlSidebarIsAllowedAgentLifecycleKey`) owns this command's single
    /// main hop app-side: it snapshots the tab/panel directory candidates on
    /// main and runs the registry disk IO on the calling thread.
    nonisolated func sidebarSetAgentLifecycle(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>]"
        guard parsed.positional.count >= 2 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        let rawLifecycle = parsed.positional[1]
        guard let lifecycleRawValue = context?.controlSidebarParseAgentLifecycle(rawLifecycle) else {
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
        guard context?.controlSidebarIsAllowedAgentLifecycleKey(
            key,
            target: target,
            panelID: panelResolution.panelId
        ) ?? false else {
            return "ERROR: Unsupported agent lifecycle key '\(key)'"
        }
        context?.controlSidebarScheduleAgentLifecycle(
            target: target,
            key: key,
            lifecycleRawValue: lifecycleRawValue,
            panelID: panelResolution.panelId
        )
        return "OK"
    }

    /// `agent_hibernation` — the global hibernation toggle (the seam witness
    /// applies the settings write in its own single main hop so the change
    /// notification still posts on the main thread and the reply stays
    /// apply-then-reply, as the legacy body was).
    nonisolated func sidebarAgentHibernation(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let subcommand = parsed.positional.first?.lowercased()
        let usage = "agent_hibernation <on|off>"

        switch subcommand {
        case "on", "enable", "enabled", "true":
            context?.controlSidebarSetAgentHibernation(enabled: true)
            return "OK"
        case "off", "disable", "disabled", "false":
            context?.controlSidebarSetAgentHibernation(enabled: false)
            return "OK"
        default:
            return "ERROR: Usage: \(usage)"
        }
    }

    /// `clear_agent_pid` — unregister an agent PID (parse + bus enqueue; zero
    /// main hops).
    nonisolated func sidebarClearAgentPID(_ args: String, context: (any ControlCommandContext)?) -> String {
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
        context?.controlSidebarScheduleAgentPIDClear(
            target: target,
            key: key,
            panelID: panelResolution.panelId,
            clearStatus: parsed.options["clear-status"] != nil
        )
        return "OK"
    }

    // MARK: - Log / progress

    /// `log` — append a sidebar log entry. The tab-resolution reply
    /// (`Tab not found` / `No tab selected`) requires the synchronous append
    /// result, so the write is the command's single main hop; level
    /// validation and message assembly run on the calling thread.
    nonisolated func sidebarAppendLog(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>"
        }
        let message = parsed.positional.joined(separator: " ")
        let levelStr = parsed.options["level"] ?? "info"
        guard context?.controlSidebarIsValidLogLevel(levelStr) ?? false else {
            return "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error"
        }
        let source = parsed.options["source"]
        let tabArg = parsed.options["tab"]

        let appended = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarAppendLog(
                    tabArg: tabArg,
                    message: message,
                    levelRawValue: levelStr,
                    source: source
                )
            }
        } ?? false
        guard appended else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_log` — clear the sidebar log (one resolution hop).
    nonisolated func sidebarClearLog(_ args: String, context: (any ControlCommandContext)?) -> String {
        let tabArg = sidebarParseOptions(args).options["tab"]
        let cleared = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarClearLog(tabArg: tabArg) }
        } ?? false
        guard cleared else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }

    /// `list_log` — list sidebar log entries (limit parse, suffix slice, and
    /// line formatting off-main around one snapshot hop).
    nonisolated func sidebarListLog(_ args: String, context: (any ControlCommandContext)?) -> String {
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

        let tabArg = parsed.options["tab"]
        let snapshot = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarLogEntries(tabArg: tabArg) }
        } ?? nil
        guard let allEntries = snapshot else {
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

    /// `set_progress` — set the sidebar progress bar (value parse/clamp
    /// off-main, one resolution hop for the write).
    nonisolated func sidebarSetProgress(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        guard let first = parsed.positional.first else {
            return "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]"
        }
        guard let value = Double(first), value.isFinite else {
            return "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0"
        }
        let clamped = min(1.0, max(0.0, value))
        let label = parsed.options["label"]
        let tabArg = parsed.options["tab"]

        let applied = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarSetProgress(tabArg: tabArg, value: clamped, label: label)
            }
        } ?? false
        guard applied else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_progress` — clear the sidebar progress bar (one resolution hop).
    nonisolated func sidebarClearProgress(_ args: String, context: (any ControlCommandContext)?) -> String {
        let tabArg = sidebarParseOptions(args).options["tab"]
        let cleared = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarClearProgress(tabArg: tabArg) }
        } ?? false
        guard cleared else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }
}
