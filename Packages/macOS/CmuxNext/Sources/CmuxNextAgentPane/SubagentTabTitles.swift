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
    /// The name of each subagent pane's tab, by tab id.
    private var tabs: [String: String] = [:]
    private var tabTones: [String: Int] = [:]

    public init() {}

    /// The longest name a tab keeps.
    public static let limit = 200

    /// Records subagent `agent` of session `session` as named `title` (trimmed, at most ``limit``
    /// characters; an empty one records nothing).
    public func name(_ agent: String, of session: String, title: String?, tone: Int? = nil) {
        tones[Self.key(session, agent)] = AgentIdentityTone.valid(tone)
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        names[Self.key(session, agent)] = String(trimmed.prefix(Self.limit))
    }

    /// Gives tab `tab`, a new pane on subagent `agent` of `session`, that subagent's name, when one
    /// was recorded. `isOpen` drops the names of tabs that closed.
    public func bind(_ agent: String, of session: String, toTab tab: String, isOpen: (String) -> Bool = { _ in true }) {
        tabs = tabs.filter { isOpen($0.key) }
        tabTones = tabTones.filter { isOpen($0.key) }
        tabs[tab] = names[Self.key(session, agent)]
        tabTones[tab] = tones[Self.key(session, agent)]
    }

    /// Tab `tab` now shows a subagent named `title`, or (nil or blank) its chat again: a subagent pane
    /// shows the chat's other subagents in place, and its "Subagent of" pill goes back to the chat.
    /// Review of #28497 at 995299ff: the name bound at open stayed on the tab through those.
    /// While a shown subagent's name is loading, `keepingTitle` updates only the identity ink.
    public func show(_ title: String?, inTab tab: String, tone: Int? = nil, keepingTitle: Bool = false) {
        if !keepingTitle {
            let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            tabs[tab] = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.limit))
        }
        tabTones[tab] = AgentIdentityTone.valid(tone)
    }

    /// The name tab `tab` shows as a subagent's pane, nil for any other tab.
    public func title(ofTab tab: String) -> String? {
        tabs[tab]
    }

    /// The shared identity ink for this pane, nil for its parent or a non-agent panel.
    public func tone(ofTab tab: String) -> Int? { tabTones[tab] }

    private static func key(_ session: String, _ agent: String) -> String { "\(session)\u{1F}\(agent)" }
}
