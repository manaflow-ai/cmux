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
    /// The transcript whose pill menu was built last: its Start now row starts that transcript's agent, though
    /// another one shows the same conversation (two fixture tabs over the mock owner, or one and the playground).
    private weak var menuOrigin: HomeNativeTranscriptView?
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
        transcript.startAgentMenuItem = { [weak self, weak transcript] peer in
            self?.menuOrigin = transcript
            return self?.registry?.makeContextMenuItem(for: Self.startQueuedAgent, in: .agentChat,
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
            let (transcript, control) = chief
            let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !agent.isEmpty, transcript.isQueued(agent) else { return .refused(HomeChiefHomesStrings.notQueued) }
            // action-wait-allow: the Chief's own process starts the agent (chief.stop {start}); its session shows only once that process made it
            return .waiting(.externalProcess) {
                guard let control else {
                    // A transcript that starts its own agents (startsOwnAgents): its onStartAgent does it.
                    let started = await transcript.onStartAgent?(agent) ?? false
                    return started ? nil : ActionWorkFailure(refusal: .unavailable, reason: HomeChiefHomesStrings.notQueued)
                }
                return await control.startNow(agent).map { ActionWorkFailure(refusal: .unavailable, reason: $0.text) }
            }
        })
    }

    /// The Chief Home that can start queued agents of `conversation` (nil: the key window's, else any one), or a
    /// transcript that starts its own (no control). Of several showing `conversation`: the one whose menu was built
    /// last, else the key window's, else any.
    private func startingChief(of conversation: ConversationID?) -> (transcript: HomeNativeTranscriptView, control: HomeChiefTurnControl?)? {
        let chiefs: [(transcript: HomeNativeTranscriptView, control: HomeChiefTurnControl?)] =
            homes.allObjects.compactMap(\.startingChief).map { ($0.transcript, $0.control) }
        let own = ownStarters.allObjects.filter { $0.onStartAgent != nil }.map { (transcript: $0, control: HomeChiefTurnControl?.none) }
        let open = chiefs + own
        func key(_ view: HomeNativeTranscriptView) -> Bool { view.window?.isKeyWindow == true }
        guard let conversation else { return open.first { key($0.transcript) } ?? open.first }
        let showing = open.filter { $0.transcript.conversationID == conversation }
        return showing.first { $0.transcript === menuOrigin } ?? showing.first { key($0.transcript) } ?? showing.first
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
