import CmuxNextAgentCursor
import CmuxNextControl
import Foundation

/// What each agent cursor's tag says and where a click on it goes (user,
/// 2026-10-20: "a clickable, descriptive" tag "saying who is driving and
/// where", "Chief · <workspace name>" or "a201 · <workspace/terminal
/// title>"; a click focuses that workspace and pane). The `cmux browser`
/// path notes each session's origin (its caller, ``BrowserPageAgentOrigin``)
/// before its first input draws; a session with no known origin keeps its
/// agent's name and is no link.
@MainActor
final class AgentCursorTagLinks {
    /// A session's tag text and origin.
    struct Link: Equatable {
        var origin: BrowserPageAgentOrigin
        var label: String
    }

    private var links: [String: Link] = [:]
    private let reveal: (String) -> Bool

    /// - Parameter reveal: Shows a tab by id (its workspace, pane and window);
    ///   false when it is gone. The app passes `AppServices.revealTab`.
    init(reveal: @escaping (String) -> Bool) {
        self.reveal = reveal
    }

    /// Session `session` of agent `agent` comes from `origin`.
    func note(_ origin: BrowserPageAgentOrigin, agent: String?, session: String) {
        let name = agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let driver = origin.isChief ? Self.chief : (name.isEmpty ? Self.unnamed : name)
        links[session] = Link(origin: origin, label: AgentCursorTagLabel(driver: driver, place: origin.workspaceName).text)
    }

    /// The tag text of `session`: who and where when its origin is known,
    /// else its agent's name (``AgentCursorSessionLabel``).
    func label(for session: String) -> String? {
        links[session]?.label ?? AgentCursorSessionLabel(sessionID: session, unnamed: Self.unnamed).text
    }

    /// The link of `session`, nil when its origin is unknown.
    func link(for session: String) -> Link? { links[session] }

    /// A click or VoiceOver press on the tag of `session`: shows its origin's
    /// tab. False when the session is no link or the tab is gone.
    @discardableResult
    func press(_ session: String) -> Bool {
        guard let link = links[session] else { return false }
        return reveal(link.origin.tabID)
    }

    static var chief: String {
        String(localized: "agentCursor.tag.chief", defaultValue: "Chief", bundle: .module)
    }

    static var unnamed: String {
        String(localized: "agentCursor.tag.unnamed", defaultValue: "Agent", bundle: .module)
    }

    /// The tooltip and VoiceOver help of a tag whose origin is in `place`.
    static func goTo(_ place: String) -> String {
        String(format: String(localized: "agentCursor.tag.goTo", defaultValue: "Go to %@", bundle: .module), place)
    }

    /// What VoiceOver reads for a tag with text `label`.
    static func accessibilityLabel(_ label: String) -> String {
        String(format: String(localized: "agentCursor.tag.accessibilityLabel", defaultValue: "Agent cursor: %@", bundle: .module), label)
    }
}
