import Foundation

/// `cmux action …` and the generated `cmux <noun> <verb>` commands.
///
/// Nothing here knows any action: the catalog comes from the app's
/// `action.list` at run time, so a new action gets a CLI verb, flags, and
/// help text without CLI changes. Kept free of the rest of the CLI (only
/// Foundation) so it can be compiled and tested on its own.
final class CmuxActionCLI {
    /// Sends one v2 request and returns its `result` object.
    typealias Call = (_ method: String, _ params: [String: Any]) throws -> [String: Any]

    struct Failure: Error, CustomStringConvertible {
        let message: String
        let exitCode: Int32
        var description: String { message }

        init(_ message: String, exitCode: Int32 = 1) {
            self.message = message
            self.exitCode = exitCode
        }
    }

    /// Thrown by `Call` wrappers when the server does not implement
    /// `action.*` (the pre-rewrite app).
    struct ServerLacksActions: Error {}

    /// A structured v2 error (`{"ok": false, "error": {"code", "message"}}`),
    /// thrown by `Call` wrappers.
    struct ServerError: Error, CustomStringConvertible {
        let code: String
        let message: String
        var description: String { message }
    }

    struct Argument {
        var name: String
        var title: String
        var kind: String
        var isRequired: Bool
        var choices: [String]
        var min: Int?
        var max: Int?
        var targetKind: String?

        var flag: String { "--" + CmuxActionCLI.kebab(name) }

        var placeholder: String {
            switch kind {
            case "int":
                if let min = min, let max = max { return "<\(min)-\(max)>" }
                return "<number>"
            case "bool": return "<true|false>"
            case "enum": return "<" + choices.joined(separator: "|") + ">"
            case "target": return "<\(targetKind ?? "kind"):id>"
            default: return "<text>"
            }
        }
    }

    struct Action {
        var id: String
        var title: String
        var category: String
        var categoryTitle: String
        var cliName: String
        var noun: String
        var verb: String
        var shortcut: String?
        var arguments: [Argument]
        var targets: [String]
        var requires: [String]
        var isAvailable: Bool
        var isBound: Bool
        var raw: [String: Any]
    }

    private let call: Call
    private let jsonOutput: Bool
    private let output: (String) -> Void

    init(call: @escaping Call, jsonOutput: Bool, output: @escaping (String) -> Void) {
        self.call = call
        self.jsonOutput = jsonOutput
        self.output = output
    }

    // MARK: - Entry points

    /// `cmux action <list|describe|run|help> …`
    func runActionCommand(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            output(Self.actionUsage)
            return
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            try list(rest)
        case "describe", "show":
            let (words, _) = Self.leadingWords(rest)
            guard !words.isEmpty else { throw Failure(Self.actionUsage, exitCode: 2) }
            let action = try resolve(words.joined(separator: " "))
            if jsonOutput {
                output(Self.json(action.raw))
            } else {
                output(Self.help(for: action))
            }
        case "run", "exec":
            let (words, flags) = Self.leadingWords(rest)
            guard !words.isEmpty else { throw Failure(Self.actionUsage, exitCode: 2) }
            // `run tab-group create …` or `run tabGroup.create …`.
            let action: Action
            var positionals: [String] = []
            if words.count >= 2, let twoWord = try find(words[0] + " " + words[1]) {
                action = twoWord
                positionals = Array(words.dropFirst(2))
            } else {
                action = try resolve(words[0])
                positionals = Array(words.dropFirst())
            }
            try run(action, tokens: positionals + flags)
        case "help", "--help", "-h":
            output(Self.actionUsage)
        default:
            throw Failure(Self.actionUsage, exitCode: 2)
        }
    }

    /// `cmux <noun> [<verb>] …`. Returns false when no action uses `noun`,
    /// so the caller can report an unknown command.
    func runNounCommand(noun: String, arguments: [String]) throws -> Bool {
        let verbs = try actions(noun: noun)
        guard !verbs.isEmpty else { return false }
        guard let verb = arguments.first, !verb.hasPrefix("-") else {
            if jsonOutput {
                output(Self.json(verbs.map(\.raw)))
            } else {
                output(Self.nounHelp(noun: noun, actions: verbs))
            }
            return true
        }
        guard let action = verbs.first(where: { $0.verb == verb }) else {
            let message = String(
                format: String(localized: "cli.action.error.unknownVerb", defaultValue: "Unknown verb '%1$@' for '%2$@'."),
                verb, noun
            )
            throw Failure(message + "\n\n" + Self.nounHelp(noun: noun, actions: verbs), exitCode: 2)
        }
        try run(action, tokens: Array(arguments.dropFirst()))
        return true
    }

    // MARK: - Commands

    private func list(_ arguments: [String]) throws {
        var category: String?
        var noun: String?
        var availableOnly = false
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--category", "--noun":
                guard index + 1 < arguments.count else { throw Failure(Self.actionUsage, exitCode: 2) }
                if token == "--category" { category = arguments[index + 1] } else { noun = arguments[index + 1] }
                index += 2
            case "--available":
                availableOnly = true
                index += 1
            default:
                if token.hasPrefix("--category=") {
                    category = String(token.dropFirst("--category=".count))
                } else if token.hasPrefix("--noun=") {
                    noun = String(token.dropFirst("--noun=".count))
                } else {
                    throw Failure(Self.actionUsage, exitCode: 2)
                }
                index += 1
            }
        }
        var params: [String: Any] = [:]
        if let category = category { params["category"] = category }
        if let noun = noun { params["noun"] = noun }
        if availableOnly { params["available_only"] = true }
        let result = try call("action.list", params)
        if jsonOutput {
            output(Self.json(result))
            return
        }
        let listed = ((result["actions"] as? [[String: Any]]) ?? []).map(Self.action(from:))
        output(Self.table(listed))
    }

    private func run(_ action: Action, tokens: [String]) throws {
        let parsed = try Self.parseInvocation(tokens, for: action)
        if parsed.help {
            output(Self.help(for: action))
            return
        }
        var params: [String: Any] = ["action": action.id, "args": parsed.arguments]
        if let target = parsed.target { params["target"] = target }
        if parsed.interactive { params["interactive"] = true }
        let result = try call("action.run", params)
        output(jsonOutput ? Self.json(result) : "OK")
    }

    // MARK: - Catalog

    /// The actions for one noun (the server filters, so the CLI never
    /// downloads the whole catalog for a single verb).
    private func actions(noun: String) throws -> [Action] {
        let result = try call("action.list", ["noun": noun])
        return ((result["actions"] as? [[String: Any]]) ?? []).map(Self.action(from:))
    }

    /// Resolves an id, legacy alias, or CLI name on the server.
    private func find(_ name: String) throws -> Action? {
        do {
            let result = try call("action.describe", ["action": name])
            return (result["action"] as? [String: Any]).map(Self.action(from:))
        } catch let error as ServerError where error.code == "not_found" {
            return nil
        }
    }

    private func resolve(_ name: String) throws -> Action {
        if let action = try find(name) { return action }
        let message = String(
            format: String(localized: "cli.action.error.unknownAction", defaultValue: "Unknown action '%@'. Run 'cmux action list' to see every action."),
            name
        )
        throw Failure(message, exitCode: 2)
    }

    static func action(from raw: [String: Any]) -> Action {
        let arguments = ((raw["arguments"] as? [[String: Any]]) ?? []).map { argument -> Argument in
            Argument(
                name: argument["name"] as? String ?? "",
                title: argument["title"] as? String ?? "",
                kind: argument["kind"] as? String ?? "string",
                isRequired: argument["required"] as? Bool ?? false,
                choices: ((argument["choices"] as? [[String: Any]]) ?? []).compactMap { $0["value"] as? String },
                min: (argument["min"] as? NSNumber)?.intValue,
                max: (argument["max"] as? NSNumber)?.intValue,
                targetKind: argument["target_kind"] as? String
            )
        }
        let cliName = raw["cli_name"] as? String ?? ""
        let words = cliName.split(separator: " ", maxSplits: 1).map(String.init)
        return Action(
            id: raw["id"] as? String ?? "",
            title: raw["title"] as? String ?? "",
            category: raw["category"] as? String ?? "",
            categoryTitle: raw["category_title"] as? String ?? (raw["category"] as? String ?? ""),
            cliName: cliName,
            noun: raw["noun"] as? String ?? words.first ?? "",
            verb: raw["verb"] as? String ?? (words.count > 1 ? words[1] : ""),
            shortcut: raw["shortcut"] as? String,
            arguments: arguments,
            targets: raw["targets"] as? [String] ?? [],
            requires: raw["requires"] as? [String] ?? [],
            isAvailable: raw["available"] as? Bool ?? true,
            isBound: raw["bound"] as? Bool ?? true,
            raw: raw
        )
    }

    // MARK: - Parsing

    struct Invocation {
        var arguments: [String: String] = [:]
        var target: String?
        var interactive = false
        var help = false
    }

    /// Maps flags and positionals onto an action's schema:
    /// `--<arg> value`, `--<arg>=value`, `--arg name=value`, bool
    /// `--<arg>` / `--no-<arg>`, `--target kind:id` (or a bare id for the
    /// action's first target kind), `--<target-kind> id`, and positionals
    /// for the remaining arguments in schema order, then the target.
    static func parseInvocation(_ tokens: [String], for action: Action) throws -> Invocation {
        var invocation = Invocation()
        var positionals: [String] = []
        var index = 0
        func value(after flag: String) throws -> String {
            guard index + 1 < tokens.count else {
                let message = String(format: String(localized: "cli.action.error.missingValue", defaultValue: "%@ requires a value."), flag)
                throw Failure(message + "\n\n" + usageLine(for: action), exitCode: 2)
            }
            index += 1
            return tokens[index]
        }
        while index < tokens.count {
            let token = tokens[index]
            defer { index += 1 }
            if token == "--" {
                positionals += tokens[(index + 1)...]
                index = tokens.count
                break
            }
            guard token.hasPrefix("--"), token.count > 2 else {
                if token == "-h" { invocation.help = true } else { positionals.append(token) }
                continue
            }
            let body = String(token.dropFirst(2))
            let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
            let flagName = parts[0]
            let inlineValue = parts.count > 1 ? parts[1] : nil
            switch flagName {
            case "help":
                invocation.help = true
            case "interactive":
                invocation.interactive = true
            case "target":
                invocation.target = try inlineValue ?? value(after: token)
            case "arg":
                let pair = try inlineValue ?? value(after: token)
                guard let equals = pair.firstIndex(of: "=") else {
                    throw Failure(String(localized: "cli.action.error.argFormat", defaultValue: "--arg takes name=value."), exitCode: 2)
                }
                invocation.arguments[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            default:
                if let argument = action.arguments.first(where: { matches(flagName, $0.name) }) {
                    if argument.kind == "bool", inlineValue == nil,
                       index + 1 >= tokens.count || tokens[index + 1].hasPrefix("--") || !isBoolLiteral(tokens[index + 1]) {
                        invocation.arguments[argument.name] = "true"
                    } else {
                        invocation.arguments[argument.name] = try inlineValue ?? value(after: token)
                    }
                } else if flagName.hasPrefix("no-"),
                          let argument = action.arguments.first(where: { $0.kind == "bool" && matches(String(flagName.dropFirst(3)), $0.name) }) {
                    invocation.arguments[argument.name] = "false"
                } else if let kind = action.targets.first(where: { matches(flagName, $0) }) {
                    let id = try inlineValue ?? value(after: token)
                    invocation.target = kind + ":" + id
                } else {
                    let message = String(format: String(localized: "cli.action.error.unknownFlag", defaultValue: "Unknown option %@."), "--" + flagName)
                    throw Failure(message + "\n\n" + usageLine(for: action), exitCode: 2)
                }
            }
        }
        let open = action.arguments.filter { invocation.arguments[$0.name] == nil }
        let ordered = open.filter(\.isRequired) + open.filter { !$0.isRequired }
        var remaining = positionals[...]
        for argument in ordered {
            guard let next = remaining.popFirst() else { break }
            invocation.arguments[argument.name] = next
        }
        if let next = remaining.first, invocation.target == nil, !action.targets.isEmpty {
            invocation.target = next
            remaining = remaining.dropFirst()
        }
        if !remaining.isEmpty, !invocation.help {
            let message = String(
                format: String(localized: "cli.action.error.extraArguments", defaultValue: "Unexpected arguments: %@."),
                remaining.joined(separator: " ")
            )
            throw Failure(message + "\n\n" + usageLine(for: action), exitCode: 2)
        }
        return invocation
    }

    /// `workspace-group`, `workspaceGroup`, and `workspace_group` match.
    static func matches(_ flag: String, _ name: String) -> Bool {
        normalize(flag) == normalize(name)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0 != "-" && $0 != "_" }
    }

    static func isBoolLiteral(_ text: String) -> Bool {
        ["true", "false", "yes", "no", "on", "off", "1", "0"].contains(text.lowercased())
    }

    static func kebab(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase {
                result += "-" + character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Words before the first flag (the action name), and the rest.
    static func leadingWords(_ tokens: [String]) -> ([String], [String]) {
        let split = tokens.firstIndex { $0.hasPrefix("-") } ?? tokens.count
        return (Array(tokens[..<split]), Array(tokens[split...]))
    }

    // MARK: - Help text

    static var actionUsage: String {
        String(localized: "cli.action.usage", defaultValue: """
        Usage: cmux action list [--category <name>] [--noun <noun>] [--available] [--json]
               cmux action describe <id | noun verb> [--json]
               cmux action run <id | noun verb> [--<arg> <value> ...] [--arg name=value ...] [--target kind:id]
               cmux <noun> <verb> [--<arg> <value> ...] [--target kind:id]

        Runs any app action (the same actions as the command palette, menus, and shortcuts).
        'cmux <noun>' lists a noun's verbs; add --help to any verb for its arguments.
        """)
    }

    static func usageLine(for action: Action) -> String {
        var parts = ["cmux", action.cliName]
        for argument in action.arguments {
            let piece = argument.flag + " " + argument.placeholder
            parts.append(argument.isRequired ? piece : "[" + piece + "]")
        }
        if let kind = action.targets.first {
            parts.append("[--target \(kind):<id>]")
        }
        let label = String(localized: "cli.action.help.usage", defaultValue: "Usage:")
        return label + " " + parts.joined(separator: " ")
    }

    static func help(for action: Action) -> String {
        var lines = [usageLine(for: action), "", "\(action.title)  (\(action.id))"]
        if !action.arguments.isEmpty {
            lines.append("")
            lines.append(String(localized: "cli.action.help.arguments", defaultValue: "Arguments:"))
            let width = action.arguments.map { ($0.flag + " " + $0.placeholder).count }.max() ?? 0
            for argument in action.arguments {
                let head = (argument.flag + " " + argument.placeholder).padding(toLength: width, withPad: " ", startingAt: 0)
                let requirement = argument.isRequired
                    ? String(localized: "cli.action.help.required", defaultValue: "required")
                    : String(localized: "cli.action.help.optional", defaultValue: "optional")
                lines.append("  \(head)  \(argument.title) (\(requirement))")
            }
        }
        if !action.targets.isEmpty {
            lines.append("")
            lines.append(String(localized: "cli.action.help.target", defaultValue: "Target:"))
            let kinds = action.targets.map { "\($0):<id>" }.joined(separator: " | ")
            let focused = String(
                format: String(localized: "cli.action.help.targetDefault", defaultValue: "defaults to the focused %@"),
                action.targets[0]
            )
            lines.append("  --target \(kinds)  \(focused)")
        }
        lines.append("")
        let shortcutLabel = String(localized: "cli.action.help.shortcut", defaultValue: "Shortcut:")
        lines.append("\(shortcutLabel) \(action.shortcut ?? "-")")
        if !action.isAvailable {
            let requires = action.requires.joined(separator: ", ")
            lines.append(String(
                format: String(localized: "cli.action.help.unavailable", defaultValue: "Not available right now (needs %@)."),
                requires
            ))
        }
        if !action.isBound {
            lines.append(String(localized: "cli.action.help.unbound", defaultValue: "This build has no handler for this action yet."))
        }
        return lines.joined(separator: "\n")
    }

    static func nounHelp(noun: String, actions: [Action]) -> String {
        let label = String(localized: "cli.action.help.usage", defaultValue: "Usage:")
        var lines = ["\(label) cmux \(noun) <verb> [options]", "", String(localized: "cli.action.help.verbs", defaultValue: "Verbs:")]
        let width = actions.map(\.verb.count).max() ?? 0
        for action in actions.sorted(by: { $0.verb < $1.verb }) {
            let shortcut = action.shortcut.map { "  " + $0 } ?? ""
            lines.append("  \(action.verb.padding(toLength: width, withPad: " ", startingAt: 0))  \(action.title)\(shortcut)")
        }
        return lines.joined(separator: "\n")
    }

    static func table(_ actions: [Action]) -> String {
        var lines: [String] = []
        let width = actions.map(\.cliName.count).max() ?? 0
        var category: String?
        for action in actions {
            if action.category != category {
                if category != nil { lines.append("") }
                lines.append(action.categoryTitle)
                category = action.category
            }
            var line = "  \(action.cliName.padding(toLength: width, withPad: " ", startingAt: 0))  \(action.title)"
            if let shortcut = action.shortcut { line += "  " + shortcut }
            if !action.isBound {
                line += "  " + String(localized: "cli.action.list.unbound", defaultValue: "(no handler)")
            } else if !action.isAvailable {
                line += "  " + String(localized: "cli.action.list.unavailable", defaultValue: "(unavailable)")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Plausible generated noun: lowercase words joined by dashes.
    static func isCandidateNoun(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else { return false }
        return word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
