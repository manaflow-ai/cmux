import Foundation
import CmuxAgentChat

extension CMUXCLI {
    /// True when `cmux sessions ...` addresses the live registry in the running
    /// app rather than the saved hook records on disk.
    ///
    /// `sessions list` / `sessions debug` are deliberately socket-free, so they
    /// are dispatched before the CLI resolves a socket. `sessions live` needs
    /// the socket, so the dispatcher has to tell the two apart before it
    /// commits to the socket-free path.
    static func sessionsCommandTargetsLiveRegistry(commandArgs: [String]) -> Bool {
        guard let first = commandArgs.first else { return false }
        return ["live", "tail"].contains(
            first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Prints a bounded tail for one live session or surface through the same
    /// `surface.read_text` path used by `read-screen`.
    func runSessionsTailCommand(commandArgs: [String], socketPath: String, explicitPassword: String?, jsonOutput globalJSONOutput: Bool) throws {
        guard let target = commandArgs.dropFirst().first, !target.hasPrefix("-") else {
            throw CLIError(message: String(localized: "cli.sessions.tail.error.expectedTarget", defaultValue: "sessions tail: expected a session or surface"))
        }
        var jsonOutput = globalJSONOutput
        var lines = 3
        var index = 1
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "-n" || arg == "--lines" {
                index += 1
                guard index < commandArgs.count, let value = Int(commandArgs[index]), value > 0 else {
                    throw CLIError(message: String(localized: "cli.sessions.tail.error.invalidLines", defaultValue: "sessions tail: -n requires a positive integer"))
                }
                lines = value
            } else if arg == "--json" {
                jsonOutput = true
            } else if arg != target {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.sessions.tail.error.unexpectedArgument",
                        defaultValue: "sessions tail: unexpected argument '%@'"
                    ),
                    arg
                ))
            }
            index += 1
        }
        let client = try connectClient(socketPath: socketPath, explicitPassword: explicitPassword, launchIfNeeded: false)
        defer { client.close() }
        let session: [String: Any]
        let surfaceID: String
        if target.hasPrefix("surface:") {
            let normalized = try normalizeSurfaceHandle(target, client: client, workspaceHandle: nil, windowHandle: nil) ?? target
            session = ["session_id": target, "surface_id": normalized]
            surfaceID = normalized
        } else {
            let listing = try client.sendV2(method: "agent.sessions.list")
            let sessions = listing["sessions"] as? [[String: Any]] ?? []
            if let matched = sessions.first(where: { $0["session_id"] as? String == target }),
               let matchedSurfaceID = matched["surface_id"] as? String {
                session = matched
                surfaceID = matchedSurfaceID
            } else if UUID(uuidString: target) != nil {
                session = ["session_id": target, "surface_id": target]
                surfaceID = target
            } else {
                throw CLIError(message: String(localized: "cli.sessions.tail.error.notFound", defaultValue: "sessions tail: session or surface not found"))
            }
        }
        let payload = try client.sendV2(method: "surface.read_text", params: [
            "surface_id": surfaceID,
            "scrollback": true,
            "lines": max(lines * 4, 40),
        ])
        let text = (payload["text"] as? String) ?? (payload["viewport"] as? String) ?? ""
        let output = AgentSessionOutputPreview().tail(text, lines: lines) ?? ""
        if jsonOutput {
            print(jsonString(["session_id": session["session_id"] ?? target, "surface_id": surfaceID, "lines": lines, "last_output": output]))
        } else {
            print(output)
        }
    }

    /// Everything `cmux sessions live` accepts on the command line.
    struct SessionsLiveArguments: Equatable {
        var state: String?
        var agent: String?
        var limitRaw: String?
        var needsMe = false
        var includeAll = false
        var json = false
        var tailLines: Int?
        var settled = false
        var idleForSeconds: TimeInterval?
    }

    /// Parses `sessions live` flags in a single pass.
    ///
    /// The shared `parseOption` takes whatever token follows a flag, so
    /// `--agent --needs-me` reads `--needs-me` as the agent name: the filter
    /// then matches nothing and the command answers "nothing is waiting on
    /// you" to a caller who asked exactly the opposite question. A flag-shaped
    /// value is rejected here instead, and a value-taking flag at the end of
    /// argv says it needs a value rather than reporting itself as unknown.
    ///
    /// A value starting with a single dash still goes through, so
    /// `--limit -5` gets the limit's own "must be a positive integer" rather
    /// than a misleading complaint about a missing value.
    static func parseSessionsLiveArguments(_ args: [String]) throws -> SessionsLiveArguments {
        var parsed = SessionsLiveArguments()
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            switch arg {
            case "--needs-me":
                parsed.needsMe = true
            case "--all":
                parsed.includeAll = true
            case "--json":
                parsed.json = true
            case "--tail":
                parsed.tailLines = 3
                if index < args.count, let value = Int(args[index]), value > 0 {
                    parsed.tailLines = value
                    index += 1
                }
            case "--settled":
                parsed.settled = true
            case "--idle-for":
                let value = try sessionsLiveTakeValue(flag: arg, args: args, index: &index)
                guard let seconds = Self.sessionsLiveDuration(value) else {
                    throw CLIError(message: String(localized: "cli.sessions.live.error.invalidIdleFor", defaultValue: "sessions live: --idle-for expects a duration such as 2h"))
                }
                parsed.idleForSeconds = seconds
            case "--state", "--agent", "--limit":
                let value = try sessionsLiveTakeValue(flag: arg, args: args, index: &index)
                sessionsLiveAssign(flag: arg, value: value, into: &parsed)
            default:
                if let (flag, value) = Self.sessionsLiveInlineValue(arg) {
                    guard !value.isEmpty else {
                        throw CLIError(message: String(
                            format: String(
                                localized: "cli.sessions.live.error.missingValue",
                                defaultValue: "sessions live: %@ requires a value"
                            ),
                            flag
                        ))
                    }
                    sessionsLiveAssign(flag: flag, value: value, into: &parsed)
                    continue
                }
                // Fail closed: a typo like `--need-me` must not read as a
                // broader request than the caller typed.
                if arg.hasPrefix("-") {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.sessions.live.error.unknownFlag",
                            defaultValue: "sessions live: unknown flag '%@'"
                        ),
                        arg
                    ))
                }
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.sessions.live.error.unexpectedArgument",
                        defaultValue: "sessions live: unexpected argument '%@'"
                    ),
                    arg
                ))
            }
        }
        return parsed
    }

    private static func sessionsLiveTakeValue(
        flag: String,
        args: [String],
        index: inout Int
    ) throws -> String {
        guard index < args.count else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.sessions.live.error.missingValue",
                    defaultValue: "sessions live: %@ requires a value"
                ),
                flag
            ))
        }
        let value = args[index]
        guard !value.hasPrefix("--") else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.sessions.live.error.flagAsValue",
                    defaultValue: "sessions live: %1$@ requires a value, but '%2$@' is another flag"
                ),
                flag,
                value
            ))
        }
        index += 1
        return value
    }

    private static func sessionsLiveInlineValue(_ arg: String) -> (flag: String, value: String)? {
        for flag in ["--state", "--agent", "--limit"] where arg.hasPrefix("\(flag)=") {
            return (flag, String(arg.dropFirst(flag.count + 1)))
        }
        return nil
    }

    private static func sessionsLiveAssign(
        flag: String,
        value: String,
        into parsed: inout SessionsLiveArguments
    ) {
        switch flag {
        case "--state": parsed.state = value
        case "--agent": parsed.agent = value
        case "--limit": parsed.limitRaw = value
        default: break
        }
    }

    private static func sessionsLiveDuration(_ raw: String) -> TimeInterval? {
        let lower = raw.lowercased()
        let suffix = lower.last.map(String.init) ?? ""
        guard let value = Double(lower.dropLast()), value >= 0 else { return nil }
        switch suffix {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 60 * 60
        case "d": return value * 24 * 60 * 60
        default: return nil
        }
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
        let parsed = try Self.parseSessionsLiveArguments(commandArgs)
        let localJSONOutput = jsonOutput || parsed.json

        let stateFilter = try parsed.state.map { try Self.sessionsLiveNormalizedState($0) }
        if parsed.needsMe, let stateFilter, stateFilter != "needs_input" {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.sessions.live.error.conflictingState",
                    defaultValue: "sessions live: --needs-me conflicts with --state %@"
                ),
                stateFilter
            ))
        }

        let limit: Int
        if parsed.includeAll {
            limit = Int.max
        } else if let limitRaw = parsed.limitRaw {
            guard let value = Int(limitRaw), value > 0 else {
                throw CLIError(message: String(localized: "cli.sessions.live.error.invalidLimit", defaultValue: "sessions live: --limit must be a positive integer"))
            }
            limit = value
        } else {
            limit = 100
        }

        // Same spellings as `sessions list`, from the same resolver: the two
        // subcommands take the same `--agent` values or neither can be trusted.
        var agentFilter: String?
        if let agentRaw = parsed.agent {
            guard let canonical = Self.sessionsCanonicalAgentName(agentRaw) else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.sessions.live.error.unknownAgent",
                        defaultValue: "sessions live: unknown agent '%@'"
                    ),
                    agentRaw
                ))
            }
            agentFilter = canonical
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

        let payload = try client.sendV2(
            method: "agent.sessions.list",
            params: ["include_output": parsed.tailLines != nil]
        )
        let all = payload["sessions"] as? [[String: Any]] ?? []
        let effectiveStateFilter = parsed.needsMe ? "needs_input" : stateFilter
        let matched = all.filter { session in
            if let effectiveStateFilter, (session["state"] as? String) != effectiveStateFilter {
                return false
            }
            if let agentFilter, (session["agent"] as? String)?.lowercased() != agentFilter {
                return false
            }
            if parsed.settled, (session["settled"] as? Bool) != true { return false }
            if let idleForSeconds = parsed.idleForSeconds,
               (session["idle_for_seconds"] as? Double ?? 0) < idleForSeconds { return false }
            return true
        }
        let shown = limit == Int.max ? matched : Array(matched.prefix(limit))
        // Counted over every match, not over the rows that fit: both outputs
        // report how much is going on, and a display limit does not change
        // that.
        let counts = Self.sessionsLiveStateCounts(matched)

        if localJSONOutput {
            // `sessions` holds at most `limit` of the matched set. Truncating
            // without saying so would let a script lose sessions silently, so
            // the reply always carries both sizes and the limit that produced
            // them, the same way `sessions list --json` does.
            let outputSessions = shown.map { session -> [String: Any] in
                guard let tailLines = parsed.tailLines,
                      let output = session["last_output"] as? String else { return session }
                var copy = session
                copy["last_output"] = AgentSessionOutputPreview().tail(output, lines: tailLines)
                return copy
            }
            var out: [String: Any] = [
                "sessions": outputSessions,
                "count": shown.count,
                "total_matches": matched.count,
                "total_live": all.count,
                "limit": limit == Int.max ? NSNull() : limit,
            "state_counts": counts,
            ]
            if let tailLines = parsed.tailLines { out["tail_lines"] = tailLines }
            if let generatedAt = payload["generated_at"] {
                out["generated_at"] = generatedAt
            }
            print(jsonString(out))
            return
        }

        printSessionsLivePayload(shown, counts: counts, totalCount: all.count, tailLines: parsed.tailLines)
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
    ///
    /// Clamped because the number arrives over a socket. A nonsense
    /// `state_age_seconds` should print a nonsense age, not trap on an `Int`
    /// conversion that cannot represent it.
    static func sessionsLiveAgeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "-" }
        let total = Int(seconds.rounded().clamped(to: 0...9_999_999_999))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3_600)h" }
        return "\(total / 86_400)d"
    }

    /// State tally for a set of live sessions, keyed by wire state name plus
    /// `total`.
    ///
    /// One tally feeds both the text header and the JSON reply, so the two can
    /// never disagree about what was counted.
    static func sessionsLiveStateCounts(_ sessions: [[String: Any]]) -> [String: Int] {
        var counts: [String: Int] = ["needs_input": 0, "working": 0, "idle": 0, "ended": 0]
        for session in sessions {
            if let state = session["state"] as? String, counts[state] != nil {
                counts[state, default: 0] += 1
            }
        }
        // `total` covers every match, including any state name this CLI does
        // not know, so the buckets can sum to less than it.
        counts["total"] = sessions.count
        return counts
    }

    private func printSessionsLivePayload(
        _ sessions: [[String: Any]],
        counts: [String: Int],
        totalCount: Int,
        tailLines: Int? = nil
    ) {
        guard !sessions.isEmpty else {
            print(totalCount == 0
                ? String(localized: "cli.sessions.live.empty", defaultValue: "No live agent sessions.")
                : String(localized: "cli.sessions.live.emptyAfterFilter", defaultValue: "No live agent sessions matched."))
            return
        }

        print(sessionsLiveHeaderText(counts))
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
            if let tailLines,
               let output = AgentSessionOutputPreview().tail(session["last_output"] as? String, lines: tailLines) {
                print(output.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
            }

            var details: [String] = []
            if let cwd = session["cwd"] as? String, !cwd.isEmpty { details.append("cwd=\(cwd)") }
            if let surfaceID = session["surface_id"] as? String, !surfaceID.isEmpty {
                details.append("surface=\(surfaceID)")
            }
            if let workspaceID = session["workspace_id"] as? String, !workspaceID.isEmpty {
                details.append("workspace=\(workspaceID)")
            }
            if let branch = session["branch"] as? String, !branch.isEmpty { details.append("branch=\(branch)") }
            if let worktree = session["worktree"] as? String, !worktree.isEmpty { details.append("worktree=\(worktree)") }
            if let settled = session["settled"] as? Bool { details.append("settled=\(settled)") }
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
        // Same footer and same wording as `sessions list`: a truncated list
        // must never look like the whole list.
        let matchedCount = counts["total"] ?? sessions.count
        if matchedCount > sessions.count {
            print(String(
                format: String(localized: "cli.sessions.output.more", defaultValue: "... %lld more. Pass --all or --limit <n>."),
                matchedCount - sessions.count
            ))
        }
    }

    /// Builds the summary line from the matched tally.
    ///
    /// Emitted as `key=value` tokens rather than a sentence, on purpose: every
    /// other token in this output is already an invariant wire value (the state
    /// names in the first column, `cwd=`, `surface=`, `subagents=`,
    /// `state=unconfirmed`, and the sibling's `state_dir=`), so a translated
    /// sentence would be the one piece of prose sitting on top of untranslated
    /// data. The state names here are the same ones the rows below print and the
    /// same ones `--state` accepts, which also makes the line greppable.
    private func sessionsLiveHeaderText(_ counts: [String: Int]) -> String {
        "sessions=\(counts["total"] ?? 0)  needs_input=\(counts["needs_input"] ?? 0)  working=\(counts["working"] ?? 0)"
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
