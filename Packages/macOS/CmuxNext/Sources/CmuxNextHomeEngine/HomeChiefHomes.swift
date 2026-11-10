import AppKit
public import CmuxHomeCore
public import CmuxNextActions

/// The action that acts on a Home's Chief from anywhere: Start now on an agent the Chief queued behind its cap
/// (`home.startQueuedAgent`, user 2026-11-08). The palette, `cmux home start-agent --agent <name>` and MCP run
/// its one handler: the Chief of the Home that shows `conversation` (without one: the front window's) starts
/// `agent` past its cap, as the pill card's Start now on the Messages page does (`chief.stop {start}`). The
/// Messages pages draw the pills and their menu; the App says which Chief a conversation's Home shows
/// (``chief``).
@MainActor
public final class HomeChiefHomes {
    public static let startQueuedAgent: ActionID = "home.startQueuedAgent"
    /// The Chief control of the Home that shows `conversation` (nil: the front window's), while it can start
    /// queued agents (a Chief of this Mac or a paired server); nil when no such Home shows.
    public var chief: (@MainActor (ConversationID?) -> HomeChiefTurnControl?)?

    public init() {}

    public func bind(into registry: ActionRegistry) {
        registry.bindEffect(Self.startQueuedAgent, effect: { [weak self] invocation in
            let text = invocation["conversation"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let control = self?.chief?(text.isEmpty ? nil : ConversationID(text)) else {
                return .refused(HomeChiefHomesStrings.noChiefHome)
            }
            let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !agent.isEmpty else { return .refused(HomeChiefHomesStrings.notQueued) }
            // action-wait-allow: the Chief's own process starts the agent (chief.stop {start}); its session shows only once that process made it
            return .waiting(.externalProcess) {
                await control.startNow(agent).map { ActionWorkFailure(refusal: .unavailable, reason: $0.text) }
            }
        })
    }
}

/// Start Queued Agent Now's refusals (Resources/Home.xcstrings).
nonisolated enum HomeChiefHomesStrings {
    static var notQueued: String {
        String(localized: "home.startQueuedAgent.notQueued", defaultValue: "That agent is not waiting in the Chief’s queue.", table: "Home", bundle: .module)
    }
    static var noChiefHome: String {
        String(localized: "home.startQueuedAgent.noChiefHome", defaultValue: "Start Queued Agent Now works in a Chief’s Home", table: "Home", bundle: .module)
    }
}
