public import CmuxNextActions
public import CmuxNextAgentActivity

/// Go to Next Agent Needing Input (`agent.jumpToNextNeedingInput`, HQ #5329): the menu bar's
/// "Needs input: N" row and the palette open the next chat waiting at a question or permission
/// prompt, never a mere unread tab, cycling from the one opened last. A focus move: the handler
/// reads the chats' waiting index (``AgentPriorityChats/needingInput(now:)``, never a ranking of
/// every lane), opens on the input's own turn and returns `.done`, or refuses quietly when none waits.
@MainActor
public final class AgentNeedsInputJump {
    public static let action: ActionID = "agent.jumpToNextNeedingInput"

    private let chats: AgentPriorityChats
    /// The chat this opened last: the next run goes on from it.
    private var last: String?

    public init(chats: AgentPriorityChats) {
        self.chats = chats
    }

    /// The chat the next run opens, recorded as opened; nil when none waits.
    public func next() -> AgentActivityLane? {
        let waiting = chats.needingInput()
        guard let id = AgentPriorityRanking.next(after: last, in: waiting.map(\.id)) else {
            last = nil
            return nil
        }
        last = id
        return waiting.first { $0.id == id }
    }

    /// Binds the action into `registry` (it holds this jump); `open` shows a chat.
    public func bind(into registry: ActionRegistry, open: @escaping @MainActor (AgentActivityLane) -> Void) {
        registry.bindEffect(Self.action, effect: { [self] _ in
            guard ActionRunScope.viewChangeAllowed() else { return .done }
            guard let lane = next() else { return .refused(Self.noneWaiting, quiet: true) }
            open(lane)
            return .done
        })
    }

    static var noneWaiting: String {
        String(localized: "agent.needsInput.none", defaultValue: "No agent is waiting for input", bundle: .module)
    }
}
