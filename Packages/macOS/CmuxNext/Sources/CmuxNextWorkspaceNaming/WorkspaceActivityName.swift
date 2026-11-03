public import CmuxNextBridge
public import CmuxNextDaemon
import Foundation

/// Name from Activity (`workspace.nameFromActivity`): a short name for a workspace from what its
/// tabs show, asked of the cheapest model once, on request. Leo, 2026-10-26: "a workspace to be
/// renamed based off that existing tabs there, the recent activity that's there. You know, just
/// run it on the cheapest model."
///
/// Pure, so every case is tested: the App reads the tabs (``read(_:turns:page:)``), sends
/// ``prompt`` through acpmux's one-shot completion (`_acpmux/complete`, the path made for
/// auto-naming, hq#1957) and applies ``name(fromReply:)`` as a user rename. Only titles and short
/// snippets go out, never a transcript.
public nonisolated struct WorkspaceActivityName: Equatable, Sendable {
    /// The cheapest model; the completion runs on the person's own Claude login.
    public static let model = "claude-haiku-5-5"
    public static let harness = "claude"
    /// Enough for five words; the reply is cut to ``maxWords`` anyway.
    public static let maxTokens = 24
    /// The daemon's own limit is at most 60 s.
    public static let timeoutMs = 20_000
    /// The most words a name keeps.
    public static let maxWords = 5
    /// The most characters a snippet keeps (a prompt, a title, a folder).
    public static let snippetLimit = 120
    /// The most prompts one chat sends: its newest.
    public static let promptsPerChat = 3
    /// The most bytes a prompt takes, under `_acpmux/complete`'s 4096.
    public static let promptByteLimit = 4000
    /// The most tabs read, front first.
    public static let tabLimit = 12

    /// What one tab shows, already trimmed.
    public enum Tab: Equatable, Sendable {
        case chat(title: String?, prompts: [String])
        case terminal(folder: String?, title: String?)
        case browser(title: String?)
    }

    /// What the workspace's tabs show, front first, at most ``tabLimit``, none empty.
    public let tabs: [Tab]

    public init(tabs: [Tab]) {
        self.tabs = Array(tabs.filter { !$0.isEmpty }.prefix(Self.tabLimit))
    }

    /// Whether nothing would tell the model what the workspace is about.
    public var isEmpty: Bool { tabs.isEmpty }

    /// Reads `workspace`'s tabs in their panes' order, stopping at ``tabLimit`` tabs that say
    /// something: a crowded workspace costs no more than a small one (the action's turn budget).
    /// `page` answers a browser tab's live title, nil for an incognito page (its title never leaves
    /// memory, R102).
    @MainActor
    public static func read(_ workspace: WorkspaceModel, turns: AgentTurnStateStore,
                            page: (TabModel) -> String?) -> WorkspaceActivityName {
        var read: [Tab] = []
        for tab in workspace.screens.lazy.flatMap(\.panes).flatMap(\.tabs) {
            guard read.count < tabLimit else { break }
            if let item = Self.tab(tab, turns: turns, page: page), !item.isEmpty { read.append(item) }
        }
        return WorkspaceActivityName(tabs: read)
    }

    @MainActor
    private static func tab(_ tab: TabModel, turns: AgentTurnStateStore, page: (TabModel) -> String?) -> Tab? {
        if let session = tab.agentSession {
            // The newest prompts only: a timeline holds at most `AgentTimeline.limit` events.
            let prompts = turns.timeline(for: session).events.reversed().lazy.filter { $0.kind == .prompt }
                .compactMap(\.text).prefix(promptsPerChat).reversed()
            return .chat(title: snippet(turns.generatedTitle(for: session) ?? tab.name), prompts: prompts.compactMap(snippet))
        }
        switch tab.kind {
        case .pty, .remoteTerminal: return .terminal(folder: snippet(tab.cwd), title: snippet(tab.titleText))
        case .browser: return .browser(title: snippet(page(tab)))
        case .conversation, .other: return nil
        }
    }

    /// One line of at most ``snippetLimit`` characters; nil when empty.
    public static func snippet(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > snippetLimit ? String(line.prefix(snippetLimit - 1)) + "…" : line
    }

    /// The completion's prompt: the instruction, then each tab's lines while they fit in
    /// ``promptByteLimit`` (`_acpmux/complete` refuses a prompt over 4096 bytes).
    public var prompt: String {
        var text = [
            "Name this workspace in 2 to 5 words from what its tabs show.",
            "Reply with the name only: no quotes, no punctuation at the end, no explanation.",
            "",
            "Tabs:",
        ].joined(separator: "\n")
        for tab in tabs {
            let lines: [String]
            switch tab {
            case let .chat(title, prompts):
                lines = ["- Agent chat" + (title.map { ": \($0)" } ?? "")] + prompts.map { "  - asked: \($0)" }
            case let .terminal(folder, title):
                lines = ["- Terminal" + (folder.map { " in \($0)" } ?? "") + (title.map { ": \($0)" } ?? "")]
            case let .browser(title):
                lines = ["- Web page" + (title.map { ": \($0)" } ?? "")]
            }
            let next = text + "\n" + lines.joined(separator: "\n")
            guard next.utf8.count <= Self.promptByteLimit else { break }
            text = next
        }
        return text
    }

    /// The `_acpmux/complete` request: ``prompt`` on ``model`` through the Claude Code harness, short
    /// and bounded.
    public var completionParams: [String: any Sendable] {
        completionFallbackParams.merging(["harness": Self.harness, "model": Self.model]) { $1 }
    }

    /// The request when this machine has no Claude Code harness by that id: the default harness on
    /// its own small model (acpmux picks it: Claude's haiku alias, Codex's mini, and so on).
    public var completionFallbackParams: [String: any Sendable] {
        ["prompt": prompt, "maxTokens": Self.maxTokens, "timeoutMs": Self.timeoutMs]
    }

    /// The name in the model's reply: its first line, without quotes, a "Name:" label or a final
    /// period, at most ``maxWords`` words; nil when nothing is left.
    public static func name(fromReply reply: String) -> String? {
        guard var line = reply.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        if let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "name" {
            line = String(line[line.index(after: colon)...])
        }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’*#").union(.whitespaces))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        let words = trimmed.split(whereSeparator: \.isWhitespace).prefix(maxWords)
        return NewWorkspaceName.clean(words.joined(separator: " "))
    }
}

nonisolated extension WorkspaceActivityName.Tab {
    var isEmpty: Bool {
        switch self {
        case let .chat(title, prompts): title == nil && prompts.isEmpty
        case let .terminal(folder, title): folder == nil && title == nil
        case let .browser(title): title == nil
        }
    }
}
