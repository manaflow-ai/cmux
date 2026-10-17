import Foundation

/// `cmux chief`: the Chief home and Chief's long-term memory, without the app.
///
/// Every subcommand works on files only, so it runs while cmux is quit and
/// needs no socket. Chief itself saves facts with `cmux chief memory add`.
///
/// Home resolution matches `ChiefHome.resolve` in the CmuxChief package
/// (Packages/macOS/CmuxChief/Sources/CmuxChief/ChiefHome.swift):
/// 1. `CMUX_CHIEF_HOME` when set and non-empty;
/// 2. `~/.cmux/chief/<bundle id>`, where the bundle id is `CMUX_BUNDLE_ID`
///    (set in every cmux terminal) else the app bundle that contains this CLI,
///    reduced to a path component;
/// 3. `~/.cmux/chief/default`.
///
/// The memory file format is shared with `ChiefMemory`
/// (Packages/macOS/CmuxChief/Sources/CmuxChief/Memory/ChiefMemory.swift);
/// this CLI does not link that package, so change both together.
extension CMUXCLI {
    static let chiefUsage = String(
        localized: "cli.chief.usage",
        defaultValue: """
        Usage: cmux chief <subcommand> [options]

        Chief, cmux's home agent: its conversations, home directory and long-term memory.

        Subcommands (need a running cmux):
          open                       Show Chief Home in this window.
          dispatch [--agent codex|claude] [--name <title>] [--cwd <dir>] [--wait-working] -- <task>
                                     Start one coding agent on one task in a new workspace
                                     (`cmux chief dispatch --help` for every option).
          send [--conversation <id>] [--from <name>] [--no-reply] <text|->
                                     Send a message as you, like typing it in Home (- reads stdin).
                                     With --from, post it as a report from an agent named <name>;
                                     Chief answers it unless --no-reply is given.
          status [--json]            Print the harness, model, unread count and working conversations.
          conversations [--json]     List Chief conversations.
          read [--conversation <id>] [--limit <n>] [--json]
                                     Print the newest messages (default 20).
          stop [--conversation <id>] Stop Chief's running reply.
          approve [--deny] [--choice <option>] [--conversation <id>] [<request id>]
                                     Answer Chief's approval card (default: allow the newest waiting one).
                                     DEBUG builds only; release builds answer cards in Home.
          answer [--choice <option>]... [--text <text>] [--conversation <id>] [<message id>]
                                     Answer Chief's question card (default: the newest waiting one) as
                                     its button does. Repeat --choice for each item; unnamed items keep
                                     their preselected option. DEBUG builds only.

        Subcommands (work without a running cmux):
          home                       Print the Chief home directory.
          memory add <text|->        Save one fact Chief should remember (- reads stdin).
          memory list [--json]       List saved facts, oldest first, with their ids.
          memory forget <id>         Remove a saved fact.
          memory path [--json]       Print the memory directory and its files
                                     (person.md, instructions.md, memory.jsonl).

        Without --conversation, commands use the default Chief conversation.
        Memory never stores secrets: text that looks like a token, key or password is refused.
        The home is $CMUX_CHIEF_HOME, else ~/.cmux/chief/<app bundle id>.

        Examples:
          cmux chief send "What are my agents doing?"
          cmux chief send --from "build bot" "Release build finished"
          cmux chief read --limit 5
          cmux chief memory add "Their build machine is brave-otter"
          cmux chief memory forget m-3fa9c1d2
        """
    )

    func runChiefCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        environment: [String: String],
        bundleIdentifier: String?
    ) throws {
        if commandArgs.first?.lowercased() == "dispatch", ChiefDispatchOptions.isHelpRequest(Array(commandArgs.dropFirst())) {
            print(Self.chiefDispatchUsage)
            return
        }
        if hasHelpRequest(beforeSeparator: commandArgs) || commandArgs.isEmpty {
            print(Self.chiefUsage)
            return
        }
        let store = CLIChiefMemoryStore(
            homeDirectory: CLIChiefMemoryStore.resolveHome(environment: environment, bundleIdentifier: bundleIdentifier)
        )
        let rest = Array(commandArgs.dropFirst())
        switch commandArgs[0].lowercased() {
        case "home":
            try rejectChiefExtraArguments(rest)
            if jsonOutput {
                print(jsonString(["home": store.homeDirectory.path]))
            } else {
                print(store.homeDirectory.path)
            }
        case "memory":
            try runChiefMemoryCommand(rest, store: store, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: Self.chiefUnknownSubcommandMessage + "\n\n" + Self.chiefUsage)
        }
    }

    private static var chiefUnknownSubcommandMessage: String {
        String(
            localized: "cli.chief.error.unknownSubcommand",
            defaultValue: "Unknown chief subcommand. Try: open, dispatch, send, status, conversations, read, stop, approve, answer, home, memory"
        )
    }

    /// The subcommands that talk to the running app over the socket; the
    /// rest (`home`, `memory`, help) work on files only.
    static let chiefSocketSubcommands: Set<String> = ["open", "dispatch", "send", "status", "conversations", "read", "stop", "approve", "answer", "debug"]

    /// Whether `cmux chief <args>` needs the socket (the top-level dispatch
    /// routes those to ``runChiefSocketCommand(commandArgs:client:jsonOutput:windowOverride:)``).
    func chiefCommandNeedsSocket(_ commandArgs: [String]) -> Bool {
        guard let verb = commandArgs.first?.lowercased() else { return false }
        // A dispatch task may mention --help after `--`; only its own flags ask for help.
        if verb == "dispatch" { return !ChiefDispatchOptions.isHelpRequest(Array(commandArgs.dropFirst())) }
        guard !hasHelpRequest(beforeSeparator: commandArgs) else { return false }
        return Self.chiefSocketSubcommands.contains(verb)
    }

    private func runChiefMemoryCommand(_ args: [String], store: CLIChiefMemoryStore, jsonOutput: Bool) throws {
        guard let verb = args.first?.lowercased() else {
            throw CLIError(message: Self.chiefUsage)
        }
        let rest = Array(args.dropFirst())
        switch verb {
        case "add":
            var words = rest
            if words.first == "--" { words.removeFirst() }
            var text = words.joined(separator: " ")
            if words == ["-"] {
                text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
            // `chief` when Chief's own turn runs it (the turn sets CMUX_CHIEF_TURN, ChiefTurnContextBuilder),
            // `cli` when someone runs it in a terminal: the memory sheet names the source.
            let inTurn = ProcessInfo.processInfo.environment["CMUX_CHIEF_TURN"].map { !$0.isEmpty } ?? false
            let fact = try store.add(text, source: inTurn ? "chief" : "cli")
            if jsonOutput {
                print(jsonString(fact.jsonObject))
            } else {
                print("OK \(fact.id)")
            }
        case "list", "ls":
            try rejectChiefExtraArguments(rest)
            let facts = store.facts()
            if jsonOutput {
                print(jsonString(["facts": facts.map(\.jsonObject)]))
            } else if facts.isEmpty {
                print(String(localized: "cli.chief.memory.empty", defaultValue: "No saved facts."))
            } else {
                for fact in facts {
                    print("\(fact.id)\t\(fact.createdAt)\t\(fact.text)")
                }
            }
        case "forget", "rm":
            guard rest.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.chief.memory.forget.usage",
                    defaultValue: "Usage: cmux chief memory forget <id>"
                ))
            }
            let fact = try store.forget(rest[0])
            if jsonOutput {
                print(jsonString(fact.jsonObject))
            } else {
                print("OK \(fact.id)")
            }
        case "path", "paths":
            try rejectChiefExtraArguments(rest)
            let paths: [String: String] = [
                "directory": store.memoryDirectory.path,
                "person": store.personFile.path,
                "instructions": store.instructionsFile.path,
                "facts": store.factsFile.path,
            ]
            if jsonOutput {
                print(jsonString(paths))
            } else {
                print(store.memoryDirectory.path)
                for key in ["person", "instructions", "facts"] {
                    print("  \(key): \(paths[key] ?? "")")
                }
            }
        default:
            throw CLIError(message: String(
                localized: "cli.chief.memory.error.unknownSubcommand",
                defaultValue: "Unknown chief memory subcommand. Try: add, list, forget, path"
            ) + "\n\n" + Self.chiefUsage)
        }
    }

    private func rejectChiefExtraArguments(_ args: [String]) throws {
        guard let extra = args.first else { return }
        throw CLIError(message: String(
            localized: "cli.chief.error.unexpectedArgument",
            defaultValue: "Unexpected argument: \(extra)"
        ))
    }
}

// `cmux chief open|send|status|conversations|read|stop|debug`: the running
// app's Chief over the socket (`chief.*` v2 methods).
extension CMUXCLI {
    /// Flags and positionals of one socket subcommand.
    struct ChiefSocketArguments {
        var conversation: String?
        var from: String?
        var limit: Int?
        var noReply = false
        var mine = false
        var deny = false
        var choice: String?
        /// Every `--choice`, in order (`chief answer` takes several).
        var choices: [String] = []
        var dy: Double?
        var text: String?
        var positionals: [String] = []
    }

    static func parseChiefSocketArguments(_ args: [String]) throws -> ChiefSocketArguments {
        var parsed = ChiefSocketArguments()
        var index = 0
        func value(_ flag: String) throws -> String {
            guard index + 1 < args.count else {
                throw CLIError(message: String(
                    format: String(localized: "cli.chief.error.missingValue", defaultValue: "%@ needs a value."),
                    flag
                ))
            }
            index += 1
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--":
                parsed.positionals.append(contentsOf: args[(index + 1)...])
                index = args.count
                continue
            case "--conversation", "-c":
                parsed.conversation = try value(arg)
            case "--from":
                parsed.from = try value(arg)
            case "--limit", "-n":
                let raw = try value(arg)
                guard let limit = Int(raw), limit > 0 else {
                    throw CLIError(message: String(
                        localized: "cli.chief.error.invalidLimit",
                        defaultValue: "--limit must be a positive whole number."
                    ))
                }
                parsed.limit = limit
            case "--no-reply":
                parsed.noReply = true
            case "--mine":
                parsed.mine = true
            case "--deny":
                parsed.deny = true
            case "--choice":
                parsed.choice = try value(arg)
                parsed.choices.append(parsed.choice ?? "")
            case "--dy":
                let raw = try value(arg)
                guard let dy = Double(raw), dy.isFinite else {
                    throw CLIError(message: String(
                        format: String(localized: "cli.chief.error.invalidNumber", defaultValue: "%@ must be a number."),
                        arg
                    ))
                }
                parsed.dy = dy
            case "--text":
                parsed.text = try value(arg)
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: String(
                        format: String(localized: "cli.chief.error.unknownFlag", defaultValue: "Unknown flag: %@"),
                        arg
                    ))
                }
                parsed.positionals.append(arg)
            }
            index += 1
        }
        return parsed
    }

    /// Runs a socket subcommand (``chiefCommandNeedsSocket(_:)`` is true).
    func runChiefSocketCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?,
        environment: [String: String]
    ) throws {
        guard let verb = commandArgs.first?.lowercased() else {
            print(Self.chiefUsage)
            return
        }
        if verb == "dispatch" {
            // Its own flags (`--agent`, `--`-separated task); see CMUXCLI+ChiefDispatch.swift.
            try runChiefDispatchCommand(
                Array(commandArgs.dropFirst()), client: client, jsonOutput: jsonOutput, windowOverride: windowOverride
            )
            return
        }
        let args = try Self.parseChiefSocketArguments(Array(commandArgs.dropFirst()))
        var params: [String: Any] = [:]
        if let conversation = args.conversation { params["conversation"] = conversation }
        switch verb {
        case "open":
            try rejectChiefExtraArguments(args.positionals)
            if let window = try normalizeWindowHandle(windowOverride, client: client) {
                params["window_id"] = window
            } else if let workspace = environment["CMUX_WORKSPACE_ID"], !workspace.isEmpty {
                params["workspace_id"] = workspace
            }
            let payload = try client.sendV2(method: "chief.open", params: params)
            print(jsonOutput ? jsonString(payload) : "OK")
        case "send":
            var text = args.positionals.joined(separator: " ")
            if args.positionals == ["-"] {
                text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.chief.send.usage",
                    defaultValue: "Usage: cmux chief send [--conversation <id>] [--from <name>] [--no-reply] <text|->"
                ))
            }
            params["text"] = text
            if let from = args.from {
                params["from"] = from
                params["start_turn"] = !args.noReply
            } else if args.noReply {
                throw CLIError(message: String(
                    localized: "cli.chief.error.noReplyNeedsFrom",
                    defaultValue: "--no-reply only applies with --from."
                ))
            }
            let payload = try client.sendV2(method: "chief.send", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else if payload["queued"] as? Bool == true {
                print(String(
                    localized: "cli.chief.send.queued",
                    defaultValue: "Queued: Chief isn't connected yet; the message sends when it is."
                ))
            } else {
                print("OK \(payload["message_id"] as? String ?? payload["conversation"] as? String ?? "")")
            }
        case "status":
            try rejectChiefExtraArguments(args.positionals)
            let payload = try client.sendV2(method: "chief.status", params: params)
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            let working = payload["working"] as? [String] ?? []
            print("home\t\(payload["home"] as? String ?? "")")
            print("harness\t\(payload["harness_name"] as? String ?? payload["harness"] as? String ?? "")")
            print("model\t\(payload["model"] as? String ?? "")")
            if let effort = payload["effort"] as? String, !effort.isEmpty { print("effort\t\(effort)") }
            print("unread\t\(payload["unread"] as? Int ?? 0)")
            print("conversations\t\(payload["conversation_count"] as? Int ?? 0)")
            print("working\t\(working.isEmpty ? "-" : working.joined(separator: ","))")
            if let failure = payload["start_failure"] as? String { print("error\t\(failure)") }
        case "conversations", "list", "ls":
            try rejectChiefExtraArguments(args.positionals)
            let payload = try client.sendV2(method: "chief.conversations", params: params)
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            for row in payload["conversations"] as? [[String: Any]] ?? [] {
                let flags = [(row["working"] as? Bool == true) ? "working" : nil, (row["pinned"] as? Bool == true) ? "pinned" : nil]
                    .compactMap { $0 }.joined(separator: ",")
                print([row["id"] as? String ?? "", "\(row["unread"] as? Int ?? 0)", flags.isEmpty ? "-" : flags,
                       row["title"] as? String ?? "", Self.chiefOneLine(row["preview"] as? String ?? "")]
                    .joined(separator: "\t"))
            }
        case "read":
            try rejectChiefExtraArguments(args.positionals)
            if let limit = args.limit { params["limit"] = limit }
            let payload = try client.sendV2(method: "chief.read", params: params)
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            for message in payload["messages"] as? [[String: Any]] ?? [] {
                let at = message["at"] as? String ?? ""
                let author = message["author"] as? String ?? ""
                let text = message["text"] as? String ?? ""
                let parts = (message["parts"] as? [String] ?? []).filter { $0 != "text" }
                let suffix = parts.isEmpty ? "" : " [\(parts.joined(separator: ","))]"
                print("\(at) \(author): \(text)\(suffix)")
            }
            if payload["working"] as? Bool == true {
                print(String(localized: "cli.chief.read.working", defaultValue: "(Chief is replying…)"))
            }
        case "stop":
            try rejectChiefExtraArguments(args.positionals)
            let payload = try client.sendV2(method: "chief.stop", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else if payload["stopped"] as? Bool == true {
                print("OK")
            } else {
                print(String(localized: "cli.chief.stop.idle", defaultValue: "Chief isn't replying."))
            }
        case "approve":
            guard args.positionals.count <= 1 else { try rejectChiefExtraArguments(Array(args.positionals.dropFirst())); return }
            if let request = args.positionals.first { params["request"] = request }
            params["choice"] = args.choice ?? (args.deny ? "Deny" : "Allow")
            let payload = try client.sendV2(method: "chief.approve", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print("OK \(payload["request"] as? String ?? "") \(payload["choice"] as? String ?? "")")
            }
        case "answer":
            guard args.positionals.count <= 1 else { try rejectChiefExtraArguments(Array(args.positionals.dropFirst())); return }
            if let message = args.positionals.first { params["message"] = message }
            if !args.choices.isEmpty { params["choices"] = args.choices }
            if let text = args.text { params["text"] = text }
            let payload = try client.sendV2(method: "chief.answer", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                let lines: [String] = payload["answer"] as? [String] ?? []
                let head: [String] = ["OK \(payload["message"] as? String ?? "")"]
                print((head + lines).joined(separator: "\n"))
            }
        case "debug":
            // DEBUG builds only; hidden from help. Always prints JSON.
            guard let action = args.positionals.first else {
                throw CLIError(message: "Usage: cmux chief debug <tapback|geometry|rows|messages|scroll|set-draft|send-draft|theme|open-settings|close-settings|open-memory|close-memory|expand-tools> [--conversation <id>] [--mine] [--dy <points>] [--limit <n>] [--text <text>|<text>]")
            }
            params["action"] = action
            if args.mine { params["mine"] = true }
            if let dy = args.dy { params["dy"] = dy }
            if let limit = args.limit { params["limit"] = limit }
            let rest = args.positionals.dropFirst()
            if let text = args.text ?? (rest.isEmpty ? nil : rest.joined(separator: " ")) { params["text"] = text }
            print(jsonString(try client.sendV2(method: "chief.debug", params: params)))
        default:
            throw CLIError(message: Self.chiefUnknownSubcommandMessage + "\n\n" + Self.chiefUsage)
        }
    }

    private static func chiefOneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// One saved fact, as stored in memory.jsonl.
struct CLIChiefMemoryFact: Codable, Equatable {
    let id: String
    let text: String
    /// ISO 8601, whole seconds, UTC (`2026-10-15T12:00:00Z`).
    let createdAt: String
    let source: String

    var jsonObject: [String: Any] {
        ["id": id, "text": text, "createdAt": createdAt, "source": source]
    }
}

/// The CLI side of Chief's memory files. Same format and locking as
/// `ChiefMemory`: memory.jsonl lines are appended with one write(2) under
/// flock(LOCK_EX) on memory/.lock; forget rewrites through a temporary file
/// and rename(2) under the same lock.
struct CLIChiefMemoryStore {
    static let maxFactBytes = 1_000

    let homeDirectory: URL

    var memoryDirectory: URL { homeDirectory.appendingPathComponent("memory", isDirectory: true) }
    var personFile: URL { memoryDirectory.appendingPathComponent("person.md", isDirectory: false) }
    var instructionsFile: URL { memoryDirectory.appendingPathComponent("instructions.md", isDirectory: false) }
    var factsFile: URL { memoryDirectory.appendingPathComponent("memory.jsonl", isDirectory: false) }
    var lockFile: URL { memoryDirectory.appendingPathComponent(".lock", isDirectory: false) }

    static func resolveHome(
        environment: [String: String],
        bundleIdentifier: String?,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let explicit = environment["CMUX_CHIEF_HOME"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
        }
        let rawBundle = environment["CMUX_BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? bundleIdentifier
        let name = rawBundle.flatMap(pathComponent(of:)) ?? "default"
        return userHome
            .appendingPathComponent(".cmux/chief", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
    }

    /// Runs of anything outside `[A-Za-z0-9._]` become one `-`; nil when
    /// nothing is left. Matches `ChiefHome.component(of:)`.
    static func pathComponent(of raw: String) -> String? {
        var out = ""
        for character in raw {
            if character.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" {
                out.append(character)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? nil : trimmed
    }

    func facts() -> [CLIChiefMemoryFact] {
        let text = (try? String(contentsOf: factsFile, encoding: .utf8)) ?? ""
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(CLIChiefMemoryFact.self, from: Data(line.utf8))
        }
    }

    func add(_ rawText: String, source: String) throws -> CLIChiefMemoryFact {
        let text = rawText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !text.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.chief.memory.error.empty",
                defaultValue: "Nothing to save. Usage: cmux chief memory add <text>"
            ))
        }
        guard text.utf8.count <= Self.maxFactBytes else {
            throw CLIError(message: String(
                localized: "cli.chief.memory.error.tooLong",
                defaultValue: "That fact is too long. Keep each fact under 1,000 bytes."
            ))
        }
        guard !Self.looksLikeSecret(text) else {
            throw CLIError(message: String(
                localized: "cli.chief.memory.error.secret",
                defaultValue: "That looks like a secret (a token, key or password). Chief's memory never stores secrets."
            ))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fact = CLIChiefMemoryFact(
            id: "m-" + hex.prefix(8),
            text: text,
            createdAt: formatter.string(from: Date()),
            source: source
        )
        let line = try Self.encodeLine(fact)
        try withLock {
            let fd = open(factsFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { throw Self.ioError("open \(factsFile.path)") }
            defer { close(fd) }
            try Self.writeAll(fd: fd, data: line)
        }
        return fact
    }

    func forget(_ rawID: String) throws -> CLIChiefMemoryFact {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try withLock {
            let all = facts()
            guard let removed = all.first(where: { $0.id == id }) else {
                throw CLIError(message: String(
                    localized: "cli.chief.memory.error.notFound",
                    defaultValue: "No saved fact has id \(id). Run `cmux chief memory list` to see ids."
                ))
            }
            var data = Data()
            for fact in all where fact.id != id { data.append(try Self.encodeLine(fact)) }
            let temporary = memoryDirectory.appendingPathComponent(".memory.jsonl.\(getpid()).tmp")
            do {
                try data.write(to: temporary)
            } catch {
                throw CLIError(message: "\(error)")
            }
            _ = chmod(temporary.path, 0o600)
            guard rename(temporary.path, factsFile.path) == 0 else {
                let failure = Self.ioError("rename")
                try? FileManager.default.removeItem(at: temporary)
                throw failure
            }
            return removed
        }
    }

    /// Same patterns as `ChiefMemory.looksLikeSecret`.
    static func looksLikeSecret(_ text: String) -> Bool {
        let patterns = [
            #"(?i)BEGIN [A-Z ]*PRIVATE KEY"#,
            #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{20,}"#,
            #"(?<![A-Za-z0-9])[sr]k_(live|test)_[A-Za-z0-9]{10,}"#,
            #"(?<![A-Za-z0-9])(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,
            #"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}"#,
            #"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\-]{20,}"#,
            #"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}"#,
            #"(?<![A-Za-z0-9])xox[abprse]-[A-Za-z0-9\-]{10,}"#,
            #"(?<![A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}"#,
            #"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{35}"#,
            #"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
            // `AWS_SECRET_ACCESS_KEY=…`, `GITHUB_TOKEN: …`, `my-api-key = …`: a credential name, then a value.
            #"(?i)(^|[^a-z])(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)[a-z0-9_\-]*["']?\s*[:=]\s*\S{6,}"#,
            #"://[^/\s:@]+:[^/\s@]+@"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CLIError(message: "\(error)")
        }
        let fd = open(lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw Self.ioError("open \(lockFile.path)") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Self.ioError("flock") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func encodeLine(_ fact: CLIChiefMemoryFact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(fact)
        data.append(0x0A)
        return data
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ioError("write")
                }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
    }

    private static func ioError(_ operation: String) -> CLIError {
        CLIError(message: "\(operation): \(String(cString: strerror(errno)))")
    }
}
