public import CmuxNextDaemon
import Foundation

/// Who a session is, as acpmux keeps it (SessionSummary `displayName`, `formerNames`, `icon`): the name a
/// person or the agent gave it ("Mango"), the names it had before (oldest first) and the icon it set for
/// itself. Leo: "BUT WHO IS MANGO? ... RENAMES NEED TO BE PROPAGATED TO THE VISIBLE AREAS ... SET CUSTOM
/// ICONS FOR YOURSELVES IN THE TABS". acpmux decides all of it; the app only reads the fields.
///
/// ```swift
/// let identity = AgentSessionIdentity.of(summary: ["displayName": "Mango", "formerNames": ["old"],
///                                                  "icon": ["kind": "emoji", "text": "🥭", "source": "session"]])
/// identity?.formerName // "old"
/// ```
public nonisolated struct AgentSessionIdentity: Equatable, Sendable {
    /// The name given to the session; nil when none was.
    public var displayName: String?
    /// The names it had before, oldest first.
    public var formerNames: [String]
    /// The icon the session set for itself: the same JSON as a harness's `iconSpec`.
    public var icon: HarnessIconSpec?

    public init(displayName: String? = nil, formerNames: [String] = [], icon: HarnessIconSpec? = nil) {
        self.displayName = displayName
        self.formerNames = formerNames
        self.icon = icon
    }

    /// The name it had just before this one (the newest of ``formerNames``).
    public var formerName: String? { formerNames.last }

    /// A summary's identity; nil when it carries none of the fields (an older acpmux, or none given).
    public static func of(summary: [String: Any]) -> AgentSessionIdentity? {
        let identity = AgentSessionIdentity(
            displayName: displayName(summary),
            formerNames: (summary["formerNames"] as? [Any] ?? []).compactMap(nonEmpty),
            icon: HarnessIconSpec(json: summary["icon"]))
        return identity == AgentSessionIdentity() ? nil : identity
    }

    /// A summary's `displayName`, when it has a non-blank one.
    public static func displayName(_ summary: [String: Any]) -> String? { nonEmpty(summary["displayName"]) }

    /// The identity of every session of a watch result that has one.
    public static func identities(_ result: [String: Any]) -> [String: AgentSessionIdentity] {
        var identities: [String: AgentSessionIdentity] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let identity = of(summary: summary) { identities[id] = identity }
        }
        return identities
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
