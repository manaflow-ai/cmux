import Foundation

/// One row per coding agent, projected from the same `current.list` snapshot as
/// `cmux current`, so the list and Find Work never disagree about what exists.
struct AgentsCommand {
    static let usage = String(localized: "cli.agents.help", defaultValue: """
            Usage: cmux agents [ls] [--all] [--state <state>] [--json]
                   cmux agents open <name|resource|session-id>

            List the coding agents cmux knows about across local, SSH and Cloud
            terminals: name, state, agent kind, where it runs, cwd and pull requests.
            Rows needing input come first, then working, idle and ended agents.
            Reads cached facts only; nothing is refreshed, typed or focused.

            open jumps to the agent's terminal. It matches a resource ref or session
            id, then an exact name, then a unique part of a name (case-insensitive).
            An ambiguous name lists the candidates instead of guessing.

            Flags:
              --all            Include ended agents
              --state <state>  Only needs_input, working, idle, unknown or ended (repeatable)
              --json           Machine-readable rows with stable resource refs and session ids

            Examples:
              cmux agents
              cmux agents --state needs_input
              cmux agents --json
              cmux agents open "review pr"
            """)

    static let states = ["needs_input", "working", "idle", "unknown", "ended"]
    private static let detectionSources: Set<String> = ["hook", "plugin", "detected", "socket"]
    /// Remote daemon badges (SSH, Cloud) use the cmux-tui state names.
    private static let remoteStateNames = ["blocked": "needs_input", "done": "ended"]

    enum Action: Equatable {
        case list
        case open(String)
    }

    struct Options {
        var action: Action = .list
        var includeEnded = false
        var states: Set<String> = []
        var jsonOutput = false
    }

    struct Row {
        var name: String
        var agent: String
        var state: String
        var sessionID: String?
        var lastActivityAt: String?
        var resourceRef: String
        var placementKind: String
        var machine: String
        var cwd: String?
        var workspaceID: String?
        var panelID: String?
        var attention: [String]
        var pullRequests: [[String: Any]]

        var json: [String: Any] {
            var result: [String: Any] = [
                "name": name,
                "agent": agent,
                "state": state,
                "resource_ref": resourceRef,
                "placement": ["kind": placementKind, "machine": machine],
                "attention": attention,
                "pull_requests": pullRequests,
            ]
            result["session_id"] = sessionID
            result["last_activity_at"] = lastActivityAt
            result["cwd"] = cwd
            result["workspace_id"] = workspaceID
            result["panel_id"] = panelID
            return result
        }
    }

    let options: Options

    init(arguments args: [String]) throws {
        var result = Options()
        var positional: [String] = []
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--json" {
                result.jsonOutput = true
            } else if argument == "--all" {
                result.includeEnded = true
            } else if argument == "--state" || argument.hasPrefix("--state=") {
                let raw: String
                if argument == "--state" {
                    index += 1
                    guard index < args.count else { throw Self.argumentError(argument) }
                    raw = args[index]
                } else {
                    raw = String(argument.dropFirst("--state=".count))
                }
                let state = raw.lowercased().replacingOccurrences(of: "-", with: "_")
                guard Self.states.contains(state) else { throw Self.argumentError(raw) }
                result.states.insert(state)
            } else if argument.hasPrefix("-") {
                throw Self.argumentError(argument)
            } else {
                positional.append(argument)
            }
            index += 1
        }
        switch positional.first?.lowercased() {
        case nil, "ls", "list":
            guard positional.count <= 1 else { throw Self.argumentError(positional[1]) }
        case "open":
            if result.includeEnded || !result.states.isEmpty { throw Self.argumentError(result.includeEnded ? "--all" : "--state") }
            let query = positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                throw CLIError(message: String(localized: "cli.agents.error.openUsage", defaultValue: "agents: open needs a name, resource ref or session id. See: cmux agents"))
            }
            result.action = .open(query)
        default:
            throw Self.argumentError(positional[0])
        }
        options = result
    }

    private static func argumentError(_ argument: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(String(localized: "cli.agents.error.argument", defaultValue: "agents: unexpected argument '%@'. Known: ls, open <name>, --all, --state <state>, --json"), argument))
    }

    /// Flattens resource items into agent rows, most urgent first. An item with
    /// several agent records (a resumed session) yields one row per record.
    static func rows(from payload: [String: Any]) throws -> [Row] {
        guard let items = payload["items"] as? [[String: Any]] else {
            throw CLIError(message: String(localized: "cli.agents.error.response", defaultValue: "agents: invalid response (missing items)"))
        }
        var rows: [Row] = []
        for item in items {
            guard let resourceRef = item["resource_ref"] as? String else { continue }
            let placement = item["placement"] as? [String: Any] ?? [:]
            let projection = (item["projections"] as? [[String: Any]])?.first ?? [:]
            let attention = (item["attention"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
            // Cloud terminals often have no title yet; the terminal key still names one row.
            let label = (item["label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = label.isEmpty ? String(resourceRef.split(separator: "/").last ?? Substring(resourceRef)) : label
            for agent in item["agents"] as? [[String: Any]] ?? [] {
                // A remote badge row carries its detection source (hook, plugin,
                // detected, socket) in `kind` today, not the agent; show unknown.
                let kind = agent["kind"] as? String ?? "unknown"
                let state = agent["state"] as? String ?? "unknown"
                rows.append(Row(
                    name: name,
                    agent: detectionSources.contains(kind) ? "unknown" : kind,
                    state: remoteStateNames[state] ?? state,
                    sessionID: agent["session_id"] as? String,
                    lastActivityAt: agent["last_activity_at"] as? String,
                    resourceRef: resourceRef,
                    placementKind: placement["kind"] as? String ?? "unknown",
                    machine: placement["machine"] as? String ?? "unknown",
                    cwd: item["cwd"] as? String,
                    workspaceID: projection["workspace_id"] as? String,
                    panelID: projection["panel_id"] as? String,
                    attention: attention,
                    pullRequests: item["pull_requests"] as? [[String: Any]] ?? []
                ))
            }
        }
        // ISO 8601 UTC timestamps sort correctly as strings.
        return rows.sorted { lhs, rhs in
            let left = urgency(lhs.state), right = urgency(rhs.state)
            if left != right { return left < right }
            if lhs.lastActivityAt != rhs.lastActivityAt { return (lhs.lastActivityAt ?? "") > (rhs.lastActivityAt ?? "") }
            return lhs.resourceRef < rhs.resourceRef
        }
    }

    private static func urgency(_ state: String) -> Int {
        states.firstIndex(of: state) ?? states.firstIndex(of: "unknown")!
    }

    func filter(_ rows: [Row]) -> [Row] {
        rows.filter { row in
            if !options.states.isEmpty { return options.states.contains(row.state) }
            return options.includeEnded || row.state != "ended"
        }
    }

    enum Resolution {
        case match(Row)
        case none
        case ambiguous([Row])
    }

    /// Live agents first, so a name unique among the listed rows never turns
    /// ambiguous because of ended sessions `cmux agents` hides; ended rows are
    /// searched only when no live row matches.
    static func resolve(_ query: String, in rows: [Row]) -> Resolution {
        let live = resolve(query, among: rows.filter { $0.state != "ended" })
        if case .none = live { return resolve(query, among: rows) }
        return live
    }

    /// Narrowest tier wins: exact ids, then an exact name, then a unique part of a
    /// name. Rows that point at the same terminal count as one candidate, and a
    /// live row is preferred over an ended one for the same terminal.
    private static func resolve(_ query: String, among rows: [Row]) -> Resolution {
        let needle = query.lowercased()
        let tiers: [(Row) -> Bool] = [
            { $0.resourceRef == query || $0.sessionID?.lowercased() == needle },
            { needle.count >= 6 && ($0.sessionID?.lowercased().hasPrefix(needle) ?? false) },
            { $0.name.lowercased() == needle },
            { $0.name.lowercased().contains(needle) },
        ]
        for tier in tiers {
            var byResource: [String: Row] = [:]
            var order: [String] = []
            for row in rows where tier(row) {
                if let existing = byResource[row.resourceRef] {
                    if existing.state == "ended" && row.state != "ended" { byResource[row.resourceRef] = row }
                } else {
                    byResource[row.resourceRef] = row
                    order.append(row.resourceRef)
                }
            }
            let candidates = order.compactMap { byResource[$0] }
            if candidates.count == 1 { return .match(candidates[0]) }
            if candidates.count > 1 { return .ambiguous(candidates) }
        }
        return .none
    }

    func render(_ rows: [Row], hiddenEnded: Bool, payload: [String: Any]) -> String {
        var lines: [String] = []
        if rows.isEmpty {
            lines.append(String(localized: "cli.agents.empty", defaultValue: "No agents observed"))
        }
        let home = NSHomeDirectory()
        let cells: [[String]] = rows.map { row in
            let isLocal = row.placementKind == "local"
            // SSH machines already read `ssh:<host>`; Cloud machines are VM ids.
            let place = isLocal ? row.placementKind
                : row.machine.hasPrefix(row.placementKind + ":") ? Self.truncated(row.machine, to: 24)
                : row.placementKind + ":" + Self.truncated(row.machine, to: 16)
            var cwd = row.cwd ?? ""
            if isLocal, !home.isEmpty, cwd == home || cwd.hasPrefix(home + "/") { cwd = "~" + cwd.dropFirst(home.count) }
            var trailing = [place, cwd].filter { !$0.isEmpty }
            let prs = row.pullRequests.compactMap { pr in (pr["number"] as? NSNumber).map { "#" + $0.stringValue } ?? pr["label"] as? String }
            trailing += prs
            return [row.state, row.agent, Self.truncated(row.name, to: 48), trailing.joined(separator: "  ")].map(Self.display)
        }
        let widths = (0..<3).map { column in cells.map { $0[column].count }.max() ?? 0 }
        for cell in cells {
            let padded = (0..<3).map { cell[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            lines.append((padded + [cell[3]]).joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        if hiddenEnded {
            lines.append(String(localized: "cli.agents.endedHidden", defaultValue: "Ended agents are hidden; --all shows them."))
        }
        if payload["truncated"] as? Bool == true {
            lines.append(String(localized: "cli.agents.limited", defaultValue: "More work was observed than one read returns; some agents may be missing."))
        }
        if !rows.isEmpty {
            lines.append(String(localized: "cli.agents.openHint", defaultValue: "Jump to one: cmux agents open <name>"))
        }
        return lines.joined(separator: "\n")
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Terminal titles and paths can carry control characters; human output must
    /// not execute escape sequences, split rows or reorder text. Format characters
    /// such as ZWJ stay, so emoji in titles survive. JSON keeps the exact values.
    private static func display(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || bidiControls.contains(scalar.value) ? " " : String(scalar)
        }.joined())
    }

    private static let bidiControls: Set<UInt32> = [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
}

extension CMUXCLI {
    func runAgentsCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let command = try AgentsCommand(arguments: commandArgs)
        let wantsJSON = jsonOutput || command.options.jsonOutput
        let payload = try client.sendV2(method: "current.list", params: ["limit": 200])
        let all = try AgentsCommand.rows(from: payload)
        switch command.options.action {
        case .list:
            let rows = command.filter(all)
            if wantsJSON {
                var result: [String: Any] = [
                    "schema_version": 1,
                    "source": "current.list",
                    "agents": rows.map(\.json),
                    "truncated": payload["truncated"] as? Bool ?? false,
                ]
                result["observed_at"] = payload["observed_at"]
                result["owner_availability"] = payload["owner_availability"]
                print(jsonString(result))
            } else {
                let hiddenEnded = command.options.states.isEmpty && !command.options.includeEnded && all.contains { $0.state == "ended" }
                print(command.render(rows, hiddenEnded: hiddenEnded, payload: payload))
            }
        case .open(let query):
            let truncated = payload["truncated"] as? Bool == true
            let incompleteSnapshotMessage = String.localizedStringWithFormat(
                String(
                    localized: "cli.agents.error.noMatchTruncated",
                    defaultValue: "agents: no agent matches '%@' in the first read; more agents exist. Pass a resource ref or session id."
                ),
                query
            )
            switch AgentsCommand.resolve(query, in: all) {
            case .none:
                if truncated {
                    throw CLIError(message: incompleteSnapshotMessage)
                }
                throw CLIError(message: String.localizedStringWithFormat(String(localized: "cli.agents.error.noMatch", defaultValue: "agents: no agent matches '%@'. See: cmux agents --all"), query))
            case .ambiguous(let candidates):
                var list = candidates.prefix(10).map { "  \($0.name)  \($0.resourceRef)" }.joined(separator: "\n")
                if candidates.count > 10 { list += "\n  …" }
                throw CLIError(message: String.localizedStringWithFormat(String(localized: "cli.agents.error.ambiguous", defaultValue: "agents: '%@' matches more than one agent; pass a longer name or a resource ref:"), query) + "\n" + list)
            case .match(let row):
                let exactReference = row.resourceRef == query || row.sessionID?.lowercased() == query.lowercased()
                if truncated, !exactReference {
                    throw CLIError(message: incompleteSnapshotMessage)
                }
                // Name the workspace that already shows the terminal. Without it the
                // app projects into the selected workspace, which fails ownership
                // checks when that workspace belongs to a Cloud machine.
                var params: [String: Any] = ["resource": row.resourceRef, "focus": true]
                if let workspaceID = row.workspaceID { params["workspace_id"] = workspaceID }
                let response = try client.sendV2(method: "surface.project", params: params, responseTimeout: 180)
                if wantsJSON {
                    print(jsonString(["agent": row.json, "surface": response]))
                } else {
                    print(String.localizedStringWithFormat(String(localized: "cli.agents.opened", defaultValue: "Opened %@ (%@)"), row.name, row.resourceRef))
                }
            }
        }
    }
}
