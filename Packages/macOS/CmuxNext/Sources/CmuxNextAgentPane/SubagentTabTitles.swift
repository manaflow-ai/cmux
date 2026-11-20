import Foundation
import CmuxNextDesign
public import Observation

/// The names subagent panes' tabs show. A subagent's pane is a tab on its chat's own acpmux session
/// (``AgentSubagentPanes``), so by session it would be named like the chat. Leo 2026-10-30:
/// "subagents shouldn't be tab-named the exact same as the parent". The page sends the subagent's
/// own name with `chat.subagentPane` (its task, for the Agent tool the call's description); the app
/// gives it to the tab it opens (``name(_:of:title:)``, then ``bind(_:of:toTab:)``), the page keeps it
/// in step with the subagent the pane shows (`chat.subagentShown`, ``show(_:inTab:)``), and the tab
/// title rule reads it (``title(ofTab:)``) after any name the person gave the tab.
@MainActor @Observable
public final class SubagentTabTitles {
    public static let shared = SubagentTabTitles()

    /// Each subagent's name as its page sent it, by session and subagent id.
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var tones: [String: Int] = [:]
    @ObservationIgnored private var marks: [String: String] = [:]
    /// The name of each subagent pane's tab, by tab id.
    private var tabs: [String: String] = [:]
    private var tabTones: [String: Int] = [:]
    /// The harness whose mark each subagent pane's tab draws, when its row draws one (by tab id).
    private var tabMarks: [String: String] = [:]
    /// The state of the subagent each subagent pane's tab shows, by tab id (``showFacts(_:inTab:)``).
    private var tabFacts: [String: SubagentTabFacts] = [:]

    public init() {}

    /// The longest name a tab keeps.
    public static let limit = 200

    /// Records subagent `agent` of session `session` as named `title` (trimmed, at most ``limit``
    /// characters; an empty one records nothing).
    public func name(_ agent: String, of session: String, title: String?, tone: Int? = nil, mark: String? = nil) {
        tones[Self.key(session, agent)] = AgentIdentityTone.valid(tone)
        marks[Self.key(session, agent)] = mark
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        names[Self.key(session, agent)] = String(trimmed.prefix(Self.limit))
    }

    /// Gives tab `tab`, a new pane on subagent `agent` of `session`, that subagent's name, when one
    /// was recorded. `isOpen` drops the names of tabs that closed.
    public func bind(_ agent: String, of session: String, toTab tab: String, isOpen: (String) -> Bool = { _ in true }) {
        tabs = tabs.filter { isOpen($0.key) }
        tabTones = tabTones.filter { isOpen($0.key) }
        tabFacts = tabFacts.filter { isOpen($0.key) }
        tabMarks = tabMarks.filter { isOpen($0.key) }
        tabs[tab] = names[Self.key(session, agent)]
        tabTones[tab] = tones[Self.key(session, agent)]
        tabMarks[tab] = marks[Self.key(session, agent)]
    }

    /// Tab `tab` now shows a subagent named `title`, or (nil or blank) its chat again: a subagent pane
    /// shows the chat's other subagents in place, and its "Subagent of" pill goes back to the chat.
    /// Review of #28497 at 995299ff: the name bound at open stayed on the tab through those.
    /// While a shown subagent's name is loading, `keepingTitle` updates only the identity ink.
    public func show(_ title: String?, inTab tab: String, tone: Int? = nil, keepingTitle: Bool = false, mark: String? = nil) {
        if !keepingTitle {
            let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            tabs[tab] = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.limit))
        }
        tabTones[tab] = AgentIdentityTone.valid(tone)
        tabMarks[tab] = mark
    }

    /// Tab `tab` now shows a subagent in state `facts`, or (nil) its chat again. Leo, 2026-11-07, on a
    /// finished subagent's tab that read "Working · 4m" like its chat: "is this your sub-agent, or is
    /// this literally just a duplicate of you?"
    public func showFacts(_ facts: SubagentTabFacts?, inTab tab: String) {
        if tabFacts[tab] != facts { tabFacts[tab] = facts }
    }

    /// The state of the subagent tab `tab` shows, nil for any other tab and while it shows its chat.
    public func facts(ofTab tab: String) -> SubagentTabFacts? { tabFacts[tab] }

    /// The name tab `tab` shows as a subagent's pane, nil for any other tab.
    public func title(ofTab tab: String) -> String? {
        tabs[tab]
    }

    /// The shared identity ink for this pane, nil for its parent or a non-agent panel.
    public func tone(ofTab tab: String) -> Int? { tabTones[tab] }

    /// The icon a subagent pane's tab draws, nil for any other tab: the mark its row in the chat
    /// draws, never its chat's. That is the subagent mark (`task.ai`, the web's `SUBAGENT_FALLBACK`)
    /// in its tone, or the harness mark the row draws for a subagent of another family (`mark`).
    /// Leo, 2026-11-12, on a subagent tab with its chat's Claude mark beside a row's sparkle: "ICON
    /// ISN'T THE SAME".
    public func icon(ofTab tab: String) -> SubagentTabIcon? {
        guard tabTones[tab] != nil else { return nil }
        return tabMarks[tab].map(SubagentTabIcon.harness) ?? .subagent
    }

    /// A page's `mark` param: a harness id, nil when absent, blank or not a plain id.
    nonisolated static func mark(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return nil }
        return id
    }

    private static func key(_ session: String, _ agent: String) -> String { "\(session)\u{1F}\(agent)" }
}

/// The icon a subagent pane's tab draws (``SubagentTabTitles/icon(ofTab:)``).
public enum SubagentTabIcon: Equatable, Sendable {
    /// The subagent mark (`task.ai`) in the subagent's tone, as its row draws it.
    case subagent
    /// The mark of the harness its row draws (a subagent of another family).
    case harness(String)

    /// The harness whose mark it draws, nil for the subagent mark.
    public var harness: String? {
        if case .harness(let id) = self { return id }
        return nil
    }
}
