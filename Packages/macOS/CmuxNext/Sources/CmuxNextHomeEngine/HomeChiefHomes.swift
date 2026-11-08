import AppKit
import CmuxHomeCore
public import CmuxNextActions
public import CmuxNextHome

/// The Chief Homes open in this app: each Home's turn actions (``turnActions(for:)``), and the action that acts
/// on a Home's Chief from anywhere, Start now on an agent the Chief queued behind its cap
/// (`home.startQueuedAgent`, user 2026-11-08). The queued agent pill's menu row (``HomeChiefTurnActions`` hands
/// the transcript the registry's row), the palette, `cmux home start-agent --agent <name>` and MCP run its one
/// handler: the Chief of the Chief Home that shows `conversation` (without one: the key window's, else any)
/// starts `agent` past its cap, as the pill card's Start now does (`chief.stop {start}`).
@MainActor
public final class HomeChiefHomes {
    public static let startQueuedAgent: ActionID = "home.startQueuedAgent"
    /// Every live Home's turn actions.
    private let homes = NSHashTable<HomeChiefTurnActions>.weakObjects()
    /// The registry ``bind(into:)`` bound; the Homes' rows and Stop run its actions.
    private(set) weak var registry: ActionRegistry?

    public init() {}

    /// The turn actions of a Home over `transcript`, listed here so the actions find its Chief.
    public func turnActions(for transcript: HomeNativeTranscriptView) -> HomeChiefTurnActions {
        let actions = HomeChiefTurnActions(transcript: transcript, homes: self)
        homes.add(actions)
        return actions
    }

    public func bind(into registry: ActionRegistry) {
        self.registry = registry
        registry.bindEffect(Self.startQueuedAgent, effect: { [weak self] invocation in
            let text = invocation["conversation"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let chief = self?.startingChief(of: text.isEmpty ? nil : ConversationID(text)) else {
                return .refused(HomeChiefHomesStrings.noChiefHome)
            }
            let control = chief.control
            let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !agent.isEmpty, chief.transcript.isQueued(agent) else { return .refused(HomeChiefHomesStrings.notQueued) }
            // action-wait-allow: the Chief's own process starts the agent (chief.stop {start}); its session shows only once that process made it
            return .waiting(.externalProcess) {
                await control.startNow(agent).map { ActionWorkFailure(refusal: .unavailable, reason: $0.text) }
            }
        })
    }

    /// The Chief Home that can start queued agents of `conversation` (nil: the key window's, else any one).
    private func startingChief(of conversation: ConversationID?) -> (transcript: HomeNativeTranscriptView, control: HomeChiefTurnControl)? {
        let open = homes.allObjects.compactMap(\.startingChief)
        if let conversation { return open.first { $0.transcript.conversationID == conversation } }
        return open.first { $0.transcript.window?.isKeyWindow == true } ?? open.first
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
