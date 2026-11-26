public import CmuxNextBridge
public import CmuxNextDaemon
import Foundation

/// Name from Activity (`workspace.nameFromActivity`): a short name for a workspace from what its
/// tabs show, asked of the cheapest model once, on request. Leo, 2026-10-26: "a workspace to be
/// renamed based off that existing tabs there, the recent activity that's there. You know, just
/// run it on the cheapest model."
///
/// The rules are Rust's (`cmux-workspace-naming` `activity`): the App reads the tabs
/// (``read(_:turns:page:)``), sends ``prompt`` through acpmux's one-shot completion
/// (`_acpmux/complete`, the path made for auto-naming, hq#1957) and applies ``name(fromReply:)`` as
/// a user rename. Only titles and short snippets go out, never a transcript.
public nonisolated struct WorkspaceActivityName: Equatable, Sendable {
    /// The most characters a snippet keeps (a prompt, a title, a folder).
    public static let snippetLimit = 120
    /// The most prompts one chat sends: its newest.
    public static let promptsPerChat = 3
    /// The most bytes a prompt takes, under `_acpmux/complete`'s 4096.
    public static let promptByteLimit = 4000
    /// The most tabs read, front first.
    public static let tabLimit = 12

    /// What one tab shows, already trimmed.
    public nonisolated enum Tab: Equatable, Sendable, Codable {
        case chat(title: String?, prompts: [String])
        case terminal(folder: String?, title: String?)
        case browser(title: String?)
    }

    /// What the workspace's tabs show, front first, at most ``tabLimit``, none empty.
    public let tabs: [Tab]
    /// The completion's prompt: the instruction, then each tab's lines while they fit in
    /// ``promptByteLimit`` (`_acpmux/complete` refuses a prompt over 4096 bytes).
    public let prompt: String
    private let params: Params
    private let fallbackParams: Params

    public init(tabs: [Tab]) {
        let reply = WorkspaceNamingRules().call("activity", ["tabs": tabs], as: Reply.self)
        self.tabs = reply?.tabs ?? []
        prompt = reply?.prompt ?? ""
        params = reply?.params ?? Params()
        fallbackParams = reply?.fallbackParams ?? Params()
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
            if let item = Self.tab(tab, turns: turns, page: page) { read.append(item) }
        }
        return WorkspaceActivityName(tabs: read)
    }

    @MainActor
    private static func tab(_ tab: TabModel, turns: AgentTurnStateStore, page: (TabModel) -> String?) -> Tab? {
        if let session = tab.agentSession {
            // The newest prompts only: a timeline holds at most `AgentTimeline.limit` events.
            let prompts = turns.timeline(for: session).events.reversed().lazy.filter { $0.kind == .prompt }
                .compactMap(\.text).prefix(promptsPerChat).reversed()
            // Another machine's title never steers a name kept as the person's own (cmux#55668).
            let title = turns.namesAreRemote(session) ? nil : turns.generatedTitle(for: session)
            return snipped(.chat(title: title ?? tab.name, prompts: Array(prompts)))
        }
        switch tab.kind {
        case .pty, .remoteTerminal: return snipped(.terminal(folder: tab.cwd, title: tab.titleText))
        case .browser: return snipped(.browser(title: page(tab)))
        case .conversation, .other: return nil
        }
    }

    /// `tab`'s texts as snippets; nil when none is left.
    private static func snipped(_ tab: Tab) -> Tab? {
        WorkspaceNamingRules().call("activity_tab", ["tab": tab], as: [String: Tab?].self)?["tab"] ?? nil
    }

    /// One line of at most ``snippetLimit`` characters; nil when empty.
    public static func snippet(_ text: String?) -> String? {
        guard let text else { return nil }
        return WorkspaceNamingRules().string("snippet", TextRequest(text: text), key: "snippet")
    }

    /// The `_acpmux/complete` request: ``prompt`` on the cheapest model (`claude-haiku-5-5`) through
    /// the Claude Code harness, short and bounded.
    public var completionParams: [String: any Sendable] { params.dictionary }

    /// The request when this machine has no Claude Code harness by that id: the default harness on
    /// its own small model (acpmux picks it: Claude's haiku alias, Codex's mini, and so on).
    public var completionFallbackParams: [String: any Sendable] { fallbackParams.dictionary }

    /// The name in the model's reply: its first line, without quotes, a "Name:" label or a final
    /// period, at most five words; nil when nothing is left.
    public static func name(fromReply reply: String) -> String? {
        WorkspaceNamingRules().string("activity_name", ["reply": reply], key: "name")
    }

    /// The `activity` op's answer.
    private nonisolated struct Reply: Decodable {
        var tabs: [Tab]
        var prompt: String
        var params: Params
        var fallbackParams: Params

        enum CodingKeys: String, CodingKey { case tabs, prompt, params, fallbackParams = "fallback_params" }
    }

    /// `_acpmux/complete`'s parameters.
    private nonisolated struct Params: Decodable, Equatable, Sendable {
        var prompt = ""
        var maxTokens = 0
        var timeoutMs = 0
        var harness: String?
        var model: String?

        var dictionary: [String: any Sendable] {
            var params: [String: any Sendable] = ["prompt": prompt, "maxTokens": maxTokens, "timeoutMs": timeoutMs]
            if let harness { params["harness"] = harness }
            if let model { params["model"] = model }
            return params
        }
    }
}
