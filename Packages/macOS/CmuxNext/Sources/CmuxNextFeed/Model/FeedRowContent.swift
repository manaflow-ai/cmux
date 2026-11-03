public import Foundation
import CmuxNextIcons

/// Where an item happened, in the person's words: the agent, the workspace and the tab, by name.
/// Feed items carry only ids (`FeedContext`), so the App resolves them against its own store
/// (``FeedModel/place``); nil parts fall back to what the poster declared.
public nonisolated struct FeedPlace: Sendable, Equatable, Hashable {
    /// The agent or harness ("Claude Code", a named chat session).
    public var agent: String?
    public var workspace: String?
    public var tab: String?

    public init(agent: String? = nil, workspace: String? = nil, tab: String? = nil) {
        self.agent = agent
        self.workspace = workspace
        self.tab = tab
    }

    /// A place whose agent is a harness id (`claude`), named as products are named.
    public init(harness: String?, workspace: String?, tab: String?) {
        self.init(agent: harness.map(Self.agentName), workspace: workspace, tab: tab)
    }

    /// The resolver ``FeedModel/place`` takes, over a store's place lookup (`DaemonStore.place`:
    /// tab, terminal, agent session, workspace in; workspace name, tab name, harness out).
    public static func lookup(
        _ find: @escaping @MainActor (String?, String?, String?, String?) -> (workspace: String?, tab: String?, harness: String?)?
    ) -> @MainActor (FeedItem) -> FeedPlace? {
        { item in
            let at = item.context
            return find(at.tab, at.terminal, at.acpSession, at.workspace).map { FeedPlace(harness: $0.harness, workspace: $0.workspace, tab: $0.tab) }
        }
    }

    /// Product names stay in English.
    static func agentName(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "gemini": "Gemini CLI"
        case "cursor": "Cursor"
        case "pi": "Pi"
        default: harness
        }
    }
}

/// Everything one Feed row says, as values: what happened, one line of detail, who did it,
/// where, and when. Built once per item change (``FeedRowsView``), compared to skip redraws, and
/// read by the row's accessibility label, so a row is never just "Agent · 3m". Main actor: its
/// formatters are shared, and rows are built where they are drawn.
struct FeedRowContent: Equatable, Identifiable {
    var id: String
    /// What happened: "Allow rm -rf build?", "Finished: updated FeedModel.swift".
    var headline: String
    /// One line of concrete detail: the command, the question, the first line of the body.
    var detail: String
    /// The detail is code (a command): drawn monospaced.
    var detailIsCode: Bool
    /// The agent or poster: "Claude Code".
    var who: String
    /// "api-server › Fix login redirect".
    var place: String
    /// "Answered on Mac", "Expired"; empty while open.
    var status: String
    /// When it happened; the row draws it relative to the model's `now` only while visible.
    var createdAt: Date
    /// The full date and time, for the tooltip and VoiceOver.
    var whenFull: String
    var icon: IconName
    var isUnread: Bool
    var isOpenRequest: Bool
    var isUrgent: Bool
    var isDimmed: Bool
    var isLocal: Bool
    var count: Int
    /// Items a collapsed inbox thread holds (1 for a single item).
    var threadCount: Int
    /// An intent on the item waits for the owner (drawn dimmed).
    var isPending = false
    /// The Inbox's shown item is this row's (or in its thread).
    var isSelected = false

    init(item: FeedItem, place: FeedPlace?, threadCount: Int = 1) {
        id = item.id
        (headline, detail, detailIsCode) = Self.lines(item)
        who = Self.who(item, place: place)
        self.place = Self.where(item, place: place, who: who)
        status = FeedStrings.closed(item) ?? ""
        createdAt = item.createdAt
        whenFull = FeedRowContent.fullDate.string(from: item.createdAt)
        icon = FeedRowContent.icon(for: item)
        isUnread = item.isUnread
        isOpenRequest = item.isOpenRequest
        isUrgent = item.isOpenRequest && item.priority >= .high
        isDimmed = item.state == .expired || item.state == .cancelled
        isLocal = item.home.isLocal
        count = item.count
        self.threadCount = threadCount
    }

    /// What happened and its one line of detail, from the item alone (no place): the list sizes
    /// its rows from this without building their values.
    nonisolated static func lines(_ item: FeedItem) -> (headline: String, detail: String, isCode: Bool) {
        let detailLine = detail(item)
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A title that only names its poster ("GitHub", "Agent") says nothing: the detail leads.
        let generic = title.isEmpty || title == item.poster.label || title == item.poster.harness
        let headline = generic && !detailLine.text.isEmpty ? detailLine.text : title
        // A detail the headline already says ("Asked: Which branch…" over "Which branch…") is left out.
        let shown = generic || detailLine.text.isEmpty || title.localizedCaseInsensitiveContains(detailLine.text) ? "" : detailLine.text
        return (headline, shown, !generic && detailLine.isCode)
    }

    /// "Claude Code, api-server › Fix login redirect: Finished: updated FeedModel.swift. Ran swift test. 3m, Today 14:05".
    var accessibilityLabel: String {
        var subject = who
        if !place.isEmpty { subject += subject.isEmpty ? place : ", \(place)" }
        var parts = [subject.isEmpty ? headline : "\(subject): \(headline)"]
        if !detail.isEmpty { parts.append(detail) }
        if !status.isEmpty { parts.append(status) }
        parts.append(whenFull)
        return parts.joined(separator: ". ")
    }

    /// The meta line under the detail: who, where and the closed state.
    var meta: String {
        [who, place, status].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Parts

    private nonisolated static func who(_ item: FeedItem, place: FeedPlace?) -> String {
        if let agent = place?.agent?.nonEmpty { return agent }
        if let harness = item.poster.harness?.nonEmpty { return harness }
        // The permission bridge's placeholder label names nobody.
        let label = item.poster.label.trimmingCharacters(in: .whitespaces)
        switch item.poster.kind {
        case .agent, .harness: return label.caseInsensitiveCompare("agent") == .orderedSame ? "" : label
        default: return label
        }
    }

    /// The resolved workspace and tab; else what the poster declared (a hook posts its folder as
    /// its label, an integration its repository), never an opaque id.
    private nonisolated static func `where`(_ item: FeedItem, place: FeedPlace?, who: String) -> String {
        let parts = [place?.workspace?.nonEmpty, place?.tab?.nonEmpty].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " › ") }
        let label = item.poster.label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label != who, item.poster.harness?.nonEmpty != nil,
              label.caseInsensitiveCompare("agent") != .orderedSame else { return "" }
        return label
    }

    private nonisolated static func detail(_ item: FeedItem) -> (text: String, isCode: Bool) {
        switch item.prompt {
        case let .approve(approve):
            if let command = approve.action.command?.firstLine.nonEmpty { return (command, true) }
            let summary = approve.action.summary.firstLine
            return (summary.isEmpty ? item.body.firstLine.plain : summary, false)
        case let .question(question): return (question.question.firstLine.plain, false)
        case let .choice(choice): return ((choice.questions.first?.question ?? "").firstLine.plain, false)
        case let .confirm(confirm): return (confirm.statement.firstLine.plain, false)
        case let .signIn(signIn): return (signIn.origin.replacingOccurrences(of: "https://", with: ""), false)
        case let .passkey(passkey): return ((passkey.rpID ?? passkey.origin).replacingOccurrences(of: "https://", with: ""), false)
        case let .file(file): return (file.purpose.firstLine.plain, false)
        case let .handoff(handoff): return ((handoff.resumeHint ?? handoff.reason).firstLine.plain, false)
        case .notice, .review, .input, .custom: return (item.body.firstLine.plain, false)
        }
    }

    nonisolated static func icon(for item: FeedItem) -> IconName {
        switch item.prompt {
        case .notice:
            switch item.poster.kind {
            case .integration: .integration
            case .server, .vm: .machineRemote
            case .automation: .automation
            case .system: item.context.terminal != nil ? .terminal : .notification
            default: .notification
            }
        case let .approve(approve):
            switch approve.action.type {
            case .command: .terminal
            case .edit: .actionEdit
            case .network: .network
            case .install: .package
            case .tool, .custom: .tools
            }
        case .question: .agentQuestion
        case .choice: .feedChoice
        case .confirm: .actionConfirm
        case .signIn: .accountSignin
        case .passkey: .accountPasskey
        case .review: .actionReview
        case .input: .feedInput
        case .file: .fileNew
        case .handoff: .agentHandoff
        case .custom: .feedCustom
        }
    }

    /// "Today at 2:05 PM", "Oct 26 at 9:12 AM": one formatter for every row.
    private static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

private nonisolated extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The first line with text.
    var firstLine: String {
        split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// Without Markdown's emphasis and code marks, so a one-line detail reads as text.
    var plain: String {
        var text = self
        for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        if text.hasPrefix("#") { text = text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        return text
    }
}
