import Foundation

extension CMUXCLI {
    /// True when `cmux sessions ...` addresses the live registry in the running
    /// app rather than the saved hook records on disk.
    ///
    /// `sessions list` / `sessions debug` are deliberately socket-free, so they
    /// are dispatched before the CLI resolves a socket. `sessions live` needs
    /// the socket, so the dispatcher has to tell the two apart before it
    /// commits to the socket-free path.
    static func sessionsCommandTargetsLiveRegistry(commandArgs: [String]) -> Bool {
        commandArgs.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "live"
    }

    /// `cmux sessions live` — the running app's view of every agent session, in
    /// attention order.
    ///
    /// The sibling `cmux sessions list` reads saved hook records off disk and
    /// answers "which sessions exist and could be restored". This one asks the
    /// app, because only the live registry knows the current state, how long
    /// the session has held it, and the conversation title. That is what makes
    /// it answer a different question: "which agent is waiting on me".
    func runSessionsLiveCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let (stateRaw, rem0) = parseOption(commandArgs, name: "--state")
        let (limitRaw, rem1) = parseOption(rem0, name: "--limit")
        let (agentRaw, rem2) = parseOption(rem1, name: "--agent")

        var needsMe = false
        var includeAll = false
        var localJSONOutput = jsonOutput
        var remaining: [String] = []
        for arg in rem2 {
            switch arg {
            case "--needs-me":
                needsMe = true
            case "--all":
                includeAll = true
            case "--json":
                localJSONOutput = true
            default:
                remaining.append(arg)
            }
        }
        // Fail closed: a typo like `--need-me` must not read as a broader
        // request than the caller typed.
        if let unknown = remaining.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: String(
                format: String(localized: "cli.sessions.live.error.unknownFlag", defaultValue: "sessions live: unknown flag '%@'"),
                unknown
            ))
        }
        if let extra = remaining.first {
            throw CLIError(message: String(
                format: String(localized: "cli.sessions.live.error.unexpectedArgument", defaultValue: "sessions live: unexpected argument '%@'"),
                extra
            ))
        }

        let stateFilter = try stateRaw.map { try Self.sessionsLiveNormalizedState($0) }
        if needsMe, let stateFilter, stateFilter != "needs_input" {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.sessions.live.error.conflictingState",
                    defaultValue: "sessions live: --needs-me conflicts with --state %@"
                ),
                stateFilter
            ))
        }

        let limit: Int
        if includeAll {
            limit = Int.max
        } else if let limitRaw {
            guard let parsed = Int(limitRaw), parsed > 0 else {
                throw CLIError(message: String(localized: "cli.sessions.live.error.invalidLimit", defaultValue: "sessions live: --limit must be a positive integer"))
            }
            limit = parsed
        } else {
            limit = 100
        }

        let agentFilter = sessionsListNormalized(agentRaw)?.lowercased()
        if agentRaw != nil, agentFilter == nil {
            throw CLIError(message: String(localized: "cli.sessions.live.error.agentRequiresValue", defaultValue: "sessions live: --agent requires a value"))
        }

        // `launchIfNeeded: false` on purpose. This is a read of what is
        // happening right now; launching cmux to answer it would both be a
        // surprise and make the answer trivially empty.
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: false
        )
        defer { client.close() }

        let payload = try client.sendV2(method: "agent.sessions.list")
        let all = payload["sessions"] as? [[String: Any]] ?? []
        let effectiveStateFilter = needsMe ? "needs_input" : stateFilter
        var selected = all.filter { session in
            if let effectiveStateFilter, (session["state"] as? String) != effectiveStateFilter {
                return false
            }
            if let agentFilter, (session["agent"] as? String)?.lowercased() != agentFilter {
                return false
            }
            return true
        }
        if selected.count > limit {
            selected = Array(selected.prefix(limit))
        }

        if localJSONOutput {
            // Re-derive the counts from what is actually being printed, so a
            // filtered reply never reports the unfiltered totals.
            var counts: [String: Int] = ["needs_input": 0, "working": 0, "idle": 0, "ended": 0]
            for session in selected {
                if let state = session["state"] as? String, counts[state] != nil {
                    counts[state, default: 0] += 1
                }
            }
            counts["total"] = selected.count
            var out: [String: Any] = [
                "sessions": selected,
                "count": selected.count,
                "state_counts": counts,
            ]
            if let generatedAt = payload["generated_at"] {
                out["generated_at"] = generatedAt
            }
            if selected.count != all.count {
                out["matched_of_total"] = all.count
            }
            print(jsonString(out))
            return
        }

        printSessionsLivePayload(selected, totalCount: all.count)
    }

    /// Accepts both the wire spelling and the hyphenated one a human will type.
    private static func sessionsLiveNormalizedState(_ raw: String) throws -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "needs_input", "needsinput": return "needs_input"
        case "working": return "working"
        case "idle": return "idle"
        case "ended": return "ended"
        default:
            throw CLIError(message: String(
                format: String(
                    localized: "cli.sessions.live.error.unknownState",
                    defaultValue: "sessions live: unknown state '%@'. Expected needs-input, working, idle or ended"
                ),
                raw
            ))
        }
    }

    /// Compact age: the caller is scanning a column, so one unit is enough.
    static func sessionsLiveAgeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3_600)h" }
        return "\(total / 86_400)d"
    }

    private func printSessionsLivePayload(_ sessions: [[String: Any]], totalCount: Int) {
        guard !sessions.isEmpty else {
            print(totalCount == 0
                ? String(localized: "cli.sessions.live.empty", defaultValue: "No live agent sessions.")
                : String(localized: "cli.sessions.live.emptyAfterFilter", defaultValue: "No live agent sessions matched."))
            return
        }

        print(sessionsLiveHeaderText(sessions))
        // The state column is padded to the widest value present rather than to
        // a constant, so a list with no needs-input rows is not indented by a
        // word that never appears in it.
        let stateWidth = sessions
            .compactMap { ($0["state"] as? String)?.count }
            .max() ?? 0
        for session in sessions {
            let state = (session["state"] as? String) ?? "unknown"
            let padded = state.padding(toLength: max(stateWidth, state.count), withPad: " ", startingAt: 0)
            let age = (session["state_age_seconds"] as? Double).map(Self.sessionsLiveAgeText) ?? "-"
            let agent = (session["agent"] as? String) ?? "unknown"
            let sessionID = (session["session_id"] as? String) ?? "unknown"
            var line = "\(padded)  \(age.padding(toLength: max(4, age.count), withPad: " ", startingAt: 0))  \(agent)  \(sessionID)"
            if let title = session["title"] as? String, !title.isEmpty {
                line += "  \(title)"
            }
            print(line)

            var details: [String] = []
            if let cwd = session["cwd"] as? String, !cwd.isEmpty { details.append("cwd=\(cwd)") }
            if let surfaceID = session["surface_id"] as? String, !surfaceID.isEmpty {
                details.append("surface=\(surfaceID)")
            }
            if let workspaceID = session["workspace_id"] as? String, !workspaceID.isEmpty {
                details.append("workspace=\(workspaceID)")
            }
            if let children = intFromAny(session["children_running"]), children > 0 {
                details.append("subagents=\(children)")
            }
            // Only worth saying when it is false, and only for a settled state:
            // a session found in the process table is reported idle without a
            // hook ever confirming it.
            if (session["state_confirmed"] as? Bool) == false {
                details.append("state=unconfirmed")
            }
            if !details.isEmpty {
                print("    " + details.joined(separator: "  "))
            }
        }
    }

    /// Builds the summary line.
    ///
    /// Count selection stays in Swift rather than in catalog plural variations
    /// because the count is resolved before the string is.
    private func sessionsLiveHeaderText(_ sessions: [[String: Any]]) -> String {
        var needsInput = 0
        var working = 0
        for session in sessions {
            switch session["state"] as? String {
            case "needs_input": needsInput += 1
            case "working": working += 1
            default: break
            }
        }
        let head = sessions.count == 1
            ? String(localized: "cli.sessions.live.header.one", defaultValue: "1 live agent session")
            : String(
                format: String(localized: "cli.sessions.live.header.other", defaultValue: "%lld live agent sessions"),
                Int64(sessions.count)
            )
        return String(
            format: String(
                localized: "cli.sessions.live.header.breakdown",
                defaultValue: "%1$@ (%2$lld needs input, %3$lld working)"
            ),
            head,
            Int64(needsInput),
            Int64(working)
        )
    }
}
