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
    /// Transcripts with no Chief that start their own agents (``startsOwnAgents(_:)``).
    private let ownStarters = NSHashTable<HomeNativeTranscriptView>.weakObjects()
    /// The registry ``bind(into:)`` bound; the Homes' rows and Stop run its actions.
    private(set) weak var registry: ActionRegistry?

    public init() {}

    /// The turn actions of a Home over `transcript`, listed here so the actions find its Chief.
    public func turnActions(for transcript: HomeNativeTranscriptView) -> HomeChiefTurnActions {
        let actions = HomeChiefTurnActions(transcript: transcript, homes: self)
        homes.add(actions)
        return actions
    }

    /// `transcript` starts its own queued agents through its `onStartAgent` (the DEBUG fixture and Agent Messages
    /// Playground over the mock owner): its pill's menu gets the registered Start now row, and the action starts
    /// the agent there when `conversation` names it.
    public func startsOwnAgents(_ transcript: HomeNativeTranscriptView) {
        ownStarters.add(transcript)
        let conversation = transcript.conversationID.rawValue
        transcript.startAgentMenuItem = { [weak self] peer in
            self?.registry?.makeContextMenuItem(for: Self.startQueuedAgent, in: .agentChat,
                                                arguments: ["agent": .string(peer), "conversation": .string(conversation)])
        }
    }

    public func bind(into registry: ActionRegistry) {
        self.registry = registry
        registry.bindEffect(Self.startQueuedAgent, effect: { [weak self] invocation in
            let text = invocation["conversation"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let chief = self?.startingChief(of: text.isEmpty ? nil : ConversationID(text)) else {
                return .refused(HomeChiefHomesStrings.noChiefHome)
            }
            let start = chief.start
            let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !agent.isEmpty, chief.transcript.isQueued(agent) else { return .refused(HomeChiefHomesStrings.notQueued) }
            // action-wait-allow: the Chief's own process starts the agent (chief.stop {start}); its session shows only once that process made it
            return .waiting(.externalProcess) {
                await start(agent).map { ActionWorkFailure(refusal: .unavailable, reason: $0) }
            }
        })
    }

    /// The Chief Home (or own starter) that can start queued agents of `conversation` (nil: the key window's,
    /// else any one), and how it starts one: nil on a start, else why not.
    private func startingChief(of conversation: ConversationID?) -> (transcript: HomeNativeTranscriptView, start: @MainActor (String) async -> String?)? {
        let chiefs = homes.allObjects.compactMap(\.startingChief).map { chief in
            (transcript: chief.transcript, start: { @MainActor (agent: String) async -> String? in await chief.control.startNow(agent)?.text })
        }
        let own = ownStarters.allObjects.compactMap { transcript -> (transcript: HomeNativeTranscriptView, start: @MainActor (String) async -> String?)? in
            guard let onStartAgent = transcript.onStartAgent else { return nil }
            return (transcript, { agent in await onStartAgent(agent) ? nil : HomeChiefHomesStrings.notQueued })
        }
        let open = chiefs + own
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
