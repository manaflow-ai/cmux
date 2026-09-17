internal import Foundation

/// The v1 split direction tokens shared by `drag_surface_to_split` /
/// `new_pane` (the typed twin of the app's `SplitDirection` compat enum).
enum ControlSidebarSplitDirectionV1: Sendable, Equatable {
    case left, right, up, down

    /// Whether the direction splits horizontally (left/right).
    var isHorizontal: Bool { self == .left || self == .right }

    /// Whether the new pane inserts on the first (left/top) side.
    var insertFirst: Bool { self == .left || self == .up }

    /// The legacy `parseSplitDirection` token table.
    static func parse(_ value: String) -> ControlSidebarSplitDirectionV1? {
        switch value.lowercased() {
        case "left", "l": return .left
        case "right", "r": return .right
        case "up", "u": return .up
        case "down", "d": return .down
        default: return nil
        }
    }
}

/// The v1 sidebar domain dispatch plus the ported option-parsing helpers the
/// sidebar metadata commands share (byte-faithful twins of the legacy
/// `tokenizeArgs` / `parseOptions` / `parseOptionsNoStop` family; the
/// originals stay app-side for the v1 notification commands and the
/// socket focus-policy path).
extension ControlCommandCoordinator {
    /// Dispatches the v1 sidebar-domain commands this coordinator owns
    /// (sidebar metadata, bonsplit pane ops, and the misc v1 surface ops);
    /// returns `nil` for anything else so the legacy v1 dispatcher can fall
    /// through.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    /// - Returns: The raw reply line, or `nil` if not owned here.
    public func handleSidebarV1(command: String, args: String) -> String? {
        // The telemetry family shares its nonisolated worker-lane bodies with
        // the socket dispatcher (`socketWorkerV1ResponseIfHandled`); dispatch
        // through the same entry so both lanes run the identical body.
        if let telemetry = handleSidebarTelemetryV1(command: command, args: args, context: context) {
            return telemetry
        }
        switch command {
        case "sidebar_state": return sidebarState(args)
        case "reset_sidebar": return sidebarReset(args)
        case "right_sidebar": return sidebarRightSidebar(args)
        case "list_panes": return sidebarListPanes()
        case "list_pane_surfaces": return sidebarListPaneSurfaces(args)
        case "focus_pane": return sidebarFocusPane(args)
        case "focus_surface_by_panel": return sidebarFocusSurfaceByPanel(args)
        case "drag_surface_to_split": return sidebarDragSurfaceToSplit(args)
        case "new_pane": return sidebarNewPane(args)
        case "new_surface": return sidebarNewSurface(args)
        case "close_surface": return sidebarCloseSurface(args)
        case "reload_config": return sidebarReloadConfig(args)
        case "refresh_surfaces": return sidebarRefreshSurfaces()
        case "surface_health": return sidebarSurfaceHealth(args)
        default: return nil
        }
    }

    /// Dispatches the v1 sidebar telemetry family (status/metadata upserts,
    /// agent PID/lifecycle, log/progress, and the report/clear/kick commands)
    /// to their nonisolated worker-lane bodies; returns `nil` for anything
    /// else. Callable from the socket-worker thread (the dispatcher's v1
    /// worker lane) and from the main actor (`handleSidebarV1`, and in-process
    /// main-thread callers on the `mainThreadCallable` inline path) — every
    /// body is non-blocking end-to-end: parse and bus enqueues never block,
    /// and each body crosses to the main actor at most once via
    /// ``ControlSidebarContext/controlSidebarOnMain(_:)``, which collapses to
    /// an inline call when already on main.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    ///   - context: The live app seam (the coordinator's own `context`,
    ///     passed explicitly because these bodies run off the main actor and
    ///     must not read the main-actor `context` property).
    /// - Returns: The raw reply line, or `nil` if not a telemetry command.
    public nonisolated func handleSidebarTelemetryV1(
        command: String,
        args: String,
        context: (any ControlCommandContext)?
    ) -> String? {
        switch command {
        case "set_status": return sidebarSetStatus(args, context: context)
        case "report_meta": return sidebarReportMeta(args, context: context)
        case "report_meta_block": return sidebarReportMetaBlock(args, context: context)
        case "clear_status": return sidebarClearStatus(args, context: context)
        case "clear_meta": return sidebarClearMeta(args, context: context)
        case "clear_meta_block": return sidebarClearMetaBlock(args, context: context)
        case "list_status": return sidebarListStatus(args, context: context)
        case "list_meta": return sidebarListMeta(args, context: context)
        case "list_meta_blocks": return sidebarListMetaBlocks(args, context: context)
        case "set_agent_pid": return sidebarSetAgentPID(args, context: context)
        case "set_agent_lifecycle": return sidebarSetAgentLifecycle(args, context: context)
        case "agent_hibernation": return sidebarAgentHibernation(args, context: context)
        case "clear_agent_pid": return sidebarClearAgentPID(args, context: context)
        case "log": return sidebarAppendLog(args, context: context)
        case "clear_log": return sidebarClearLog(args, context: context)
        case "list_log": return sidebarListLog(args, context: context)
        case "set_progress": return sidebarSetProgress(args, context: context)
        case "clear_progress": return sidebarClearProgress(args, context: context)
        case "report_git_branch": return sidebarReportGitBranch(args, context: context)
        case "clear_git_branch": return sidebarClearGitBranch(args, context: context)
        case "report_pr", "report_review": return sidebarReportPullRequest(args, context: context)
        case "clear_pr": return sidebarClearPullRequest(args, context: context)
        case "report_pr_action": return sidebarReportPullRequestAction(args, context: context)
        case "report_ports": return sidebarReportPorts(args, context: context)
        case "clear_ports": return sidebarClearPorts(args, context: context)
        case "report_pwd": return sidebarReportPwd(args, context: context)
        case "report_shell_state": return sidebarReportShellState(args, context: context)
        case "report_tty": return sidebarReportTTY(args, context: context)
        case "ports_kick": return sidebarPortsKick(args, context: context)
        default: return nil
        }
    }

    /// The sidebar-domain view of the seam. Once the integrator adds
    /// ``ControlSidebarContext`` to the ``ControlCommandContext`` umbrella this
    /// cast is statically guaranteed (and may be simplified to `context`);
    /// until then it lets the domain build standalone without touching the
    /// integrator-owned umbrella file.
    var sidebarContext: (any ControlSidebarContext)? {
        context as? any ControlSidebarContext
    }

    // MARK: - Option parsing (ported twins)

    /// Tokenizes a v1 argument string with shell-style quoting and escapes
    /// (the legacy `tokenizeArgs`).
    nonisolated func sidebarTokenizeArgs(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// Splits args into positionals and `--key[=value]` options, honoring a
    /// bare `--` stop token (the legacy `parseOptions`).
    nonisolated func sidebarParseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = sidebarTokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    /// Splits args into positionals and options, skipping bare `--` tokens
    /// instead of stopping (the legacy `parseOptionsNoStop`).
    nonisolated func sidebarParseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = sidebarTokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" {
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    /// Trims an option value, mapping empty to `nil` (the legacy
    /// `normalizedOptionValue`).
    nonisolated func sidebarNormalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses a metadata format token (the legacy `parseSidebarMetadataFormat`).
    nonisolated func sidebarParseMetadataFormat(_ raw: String) -> ControlSidebarMetadataFormat? {
        switch raw.lowercased() {
        case "plain":
            return .plain
        case "markdown", "md":
            return .markdown
        default:
            return nil
        }
    }

    /// Parses the `--tab` mutation target (the legacy
    /// `parseSidebarMutationTabTarget`).
    nonisolated func sidebarParseMutationTabTarget(
        options: [String: String]
    ) -> (target: ControlSidebarTabTarget?, error: String?) {
        if let rawTabArg = options["tab"] {
            let tabArg = rawTabArg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tabArg.isEmpty else {
                return (nil, "ERROR: Tab not found")
            }
            if let tabId = UUID(uuidString: tabArg) {
                return (.workspace(tabId), nil)
            }
            if let index = Int(tabArg), index >= 0 {
                return (.index(index), nil)
            }
            return (nil, "ERROR: Tab not found")
        }
        return (.selected, nil)
    }

    /// Parses the optional `--panel`/`--surface` id (the legacy
    /// `parseOptionalPanelIdOption`).
    nonisolated func sidebarParseOptionalPanelIdOption(
        options: [String: String],
        usage: String
    ) -> (panelId: UUID?, error: String?) {
        guard let rawPanelArg = options["panel"] ?? options["surface"] else {
            return (nil, nil)
        }
        let panelArg = rawPanelArg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else {
            return (nil, "ERROR: Missing panel id — usage: \(usage)")
        }
        guard let panelId = UUID(uuidString: panelArg) else {
            return (nil, "ERROR: Invalid panel id '\(rawPanelArg)'")
        }
        return (panelId, nil)
    }

    /// The explicit shell-integration scope when both `--tab` and `--panel`
    /// are UUIDs (the legacy `explicitSocketScope`, which stays app-side for
    /// its unit tests).
    nonisolated func sidebarExplicitScope(options: [String: String]) -> ControlSidebarPanelScope? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return ControlSidebarPanelScope(workspaceID: workspaceId, panelID: panelId)
    }

    /// Splits a metadata-block command line at the first ` -- ` separator
    /// (the legacy `splitMetadataBlockArgs`).
    nonisolated func sidebarSplitMetadataBlockArgs(_ args: String) -> (optionsPart: String, markdownPart: String?) {
        guard let separatorRange = args.range(of: " -- ") else {
            return (args, nil)
        }
        let optionsPart = String(args[..<separatorRange.lowerBound])
        let markdownPart = String(args[separatorRange.upperBound...])
        return (optionsPart, markdownPart)
    }

    /// Formats one status entry listing line (the legacy `sidebarMetadataLine`).
    nonisolated func sidebarMetadataLine(_ entry: ControlSidebarStatusEntrySnapshot) -> String {
        var line = "\(entry.key)=\(entry.value)"
        if let icon = entry.icon { line += " icon=\(icon)" }
        if let color = entry.color { line += " color=\(color)" }
        if let url = entry.urlAbsoluteString { line += " url=\(url)" }
        if entry.priority != 0 { line += " priority=\(entry.priority)" }
        if entry.format != .plain { line += " format=\(entry.format.rawValue)" }
        return line
    }

    /// Formats one metadata block listing line (the legacy
    /// `sidebarMetadataBlockLine`).
    nonisolated func sidebarMetadataBlockLine(_ block: ControlSidebarMetadataBlockSnapshot) -> String {
        var line = "\(block.key)=\(block.markdown.replacingOccurrences(of: "\n", with: "\\n"))"
        if block.priority != 0 { line += " priority=\(block.priority)" }
        return line
    }

    /// The shared pre-validation of the panel-metadata mutation commands
    /// (the parse-level head of the legacy `schedulePanelMetadataMutation`;
    /// the enqueue halves live behind the seam).
    nonisolated func sidebarPanelMutationTarget(
        options: [String: String],
        missingPanelUsage: String
    ) -> (target: ControlSidebarPanelMutationTarget?, error: String?) {
        let rawPanelArg = options["panel"] ?? options["surface"]
        let surfaceIdFromOptions: UUID?
        if let rawPanelArg {
            if rawPanelArg.isEmpty {
                return (nil, "ERROR: Missing panel id — usage: \(missingPanelUsage)")
            }
            guard let surfaceId = UUID(uuidString: rawPanelArg) else {
                return (nil, "ERROR: Invalid panel id '\(rawPanelArg)'")
            }
            surfaceIdFromOptions = surfaceId
        } else {
            surfaceIdFromOptions = nil
        }

        if let tabArg = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tabArg.isEmpty,
           UUID(uuidString: tabArg) == nil,
           Int(tabArg) == nil {
            return (nil, "ERROR: Tab not found")
        }

        let target = ControlSidebarPanelMutationTarget(
            scope: sidebarExplicitScope(options: options),
            tabArg: options["tab"],
            panelID: surfaceIdFromOptions
        )
        return (target, nil)
    }
}
