import Foundation

/// The cmux commands the Mac's composer offers in every harness chat (webviews
/// acpmux/cmuxCommands.ts) that the phone runs with lines it already has:
/// `/status` (the session's status), `/fork` (Fork Conversation to New Tab) and
/// `/continue [harness]` (Continue in another agent), and `/help` (every command in one
/// searchable sheet). `/btw` is left out: acpmux opens a
/// side chat only for the Mac's own app (`btw.remote`). `/import`, `/cd`, `/resume`,
/// `/login`, `/side` and the pass-through ones need the Mac's app.
public enum CmuxSlashCommand: String, CaseIterable, Hashable, Sendable, Identifiable {
    case status
    case fork
    case `continue`
    case help

    public var id: String { rawValue }
    public var name: String { rawValue }

    /// The Mac's description of each (its slash menu wording).
    public var summary: String {
        switch self {
        case .status: String(localized: "Show the effective harness session status.")
        case .fork: String(localized: "Fork this chat into a new chat tab")
        case .continue: String(localized: "Continue in another harness")
        case .help: String(localized: "Show every command and skill")
        }
    }

    /// What follows the name in the menu (`/continue <harness>`).
    public var hint: String? { self == .continue ? "<harness>" : nil }

    /// The command and its arguments when `text` is one of these, typed alone at the start of
    /// the message (`/fork`, `/continue codex`), case-insensitively; nil for anything else
    /// (another command, or a slash mid-text, which goes to the agent as typed).
    public static func parse(_ text: String) -> (command: CmuxSlashCommand, args: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard let command = CmuxSlashCommand(rawValue: name.lowercased()) else { return nil }
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, args)
    }

    /// Why the command can't run now, in the Mac's words, or nil when it can. `canFork`: the
    /// chat is a tab the phone can fork (a workspace tab of a started chat); `targets`:
    /// the harnesses it can continue in, when known.
    public func refusal(args: String, canFork: Bool, isRunning: Bool, targets: [AgentHandoffTarget]?) -> String? {
        switch self {
        case .status, .help:
            return nil
        case .fork:
            if !args.isEmpty { return String(localized: "/fork does not take arguments") }
            return canFork && !isRunning ? nil : String(localized: "Fork is unavailable for this chat right now")
        case .continue:
            if isRunning { return String(localized: "Continue is unavailable for this chat right now") }
            if !args.isEmpty, let targets, Self.target(args, in: targets) == nil {
                return String(localized: "No matching harness for /continue")
            }
            return nil
        }
    }

    /// The `/` list's commands: these first, then the agent's, an agent command named as one of
    /// these left out (the Mac's `mergedCommands`: cmux's runs). The composer's list and
    /// `/help`'s sheet both read it, so they never disagree.
    public static func merged(_ own: [CmuxSlashCommand], agent: [ACPAvailableCommand]) -> [ACPAvailableCommand] {
        let names = Set(own.map(\.name))
        return own.map { ACPAvailableCommand(name: $0.name, description: $0.summary, hint: $0.hint) }
            + agent.filter { !names.contains($0.name.lowercased()) }
    }

    /// `/help`'s rows: the merged commands but `/help`, those with every word of `query` in the
    /// name, argument or description (case-insensitive; a leading `/` is ignored), as the Mac's
    /// `searchHelp`.
    public static func helpRows(_ commands: [ACPAvailableCommand], query: String) -> [ACPAvailableCommand] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
            .map { String($0.drop { $0 == "/" }) }.filter { !$0.isEmpty }
        return commands.filter { command in
            guard command.name != help.name else { return false }
            let text = "\(command.name) \(command.hint ?? "") \(command.description)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// The target `/continue <name>` names: by id or by its name, case-insensitively.
    public static func target(_ name: String, in targets: [AgentHandoffTarget]) -> AgentHandoffTarget? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return targets.first { $0.id.lowercased() == needle || $0.name.lowercased() == needle }
    }
}
