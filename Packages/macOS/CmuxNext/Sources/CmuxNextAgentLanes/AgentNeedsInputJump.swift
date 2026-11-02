public import CmuxNextActions
public import CmuxNextAgentActivity
import CmuxNextBridge
public import CmuxNextDaemon

/// Go to Next Agent Needing Input (`agent.jumpToNextNeedingInput`, HQ #5329): the menu bar's
/// "Needs input: N" row and the palette open the next thing waiting for the person, never a mere
/// unread tab, cycling from the one opened last. That is every agent chat at a question or
/// permission prompt (``AgentPriorityChats/needingInput(now:)``, read from the waiting index,
/// never a ranking of every lane), then every other tab of this Mac whose terminal program or
/// agent waits (`StatusMapping.needsInput`: an acpmux turn, an OSC 7501 `blocked` record). The
/// menu bar counts the same ``targets(chats:tabs:needsInput:)``. A focus move: the handler opens on
/// the input's own turn and returns `.done`, or refuses quietly when nothing waits.
@MainActor
public final class AgentNeedsInputJump {
    public static let action: ActionID = "agent.jumpToNextNeedingInput"

    /// One thing waiting for the person.
    public enum Target: Equatable {
        /// An agent chat at a question or permission prompt.
        case chat(AgentActivityLane)
        /// A tab of this Mac (its id) whose program or agent waits, not one of the chats.
        case tab(String)

        /// The id the cycle goes on from.
        var key: String {
            switch self {
            case .chat(let lane): "chat:" + lane.id
            case .tab(let id): "tab:" + id
            }
        }
    }

    private let chats: AgentPriorityChats
    private let tabs: @MainActor () -> [TabModel]
    private let needsInput: @MainActor (TabModel) -> Bool
    /// The target this opened last: the next run goes on from it.
    private var last: String?

    /// - Parameters:
    ///   - chats: The agent chats.
    ///   - tabs: This Mac's tabs, in tree order.
    ///   - needsInput: Whether a tab waits for the person (default `StatusMapping.needsInput`).
    public init(chats: AgentPriorityChats, tabs: @escaping @MainActor () -> [TabModel],
                needsInput: (@MainActor (TabModel) -> Bool)? = nil) {
        self.chats = chats
        self.tabs = tabs
        self.needsInput = needsInput ?? Self.waits
    }

    /// Everything waiting, in the order the action visits it: the waiting chats, then each other
    /// tab that waits, once per tab; a tab that shows one of those chats is that chat's stop.
    public static func targets(chats: AgentPriorityChats, tabs: [TabModel],
                               needsInput: (@MainActor (TabModel) -> Bool)? = nil) -> [Target] {
        let needsInput = needsInput ?? Self.waits
        let waiting = chats.needingInput()
        let sessions = Set(waiting.map(\.id))
        var seen = Set<String>()
        let blocked = tabs.filter { tab in
            seen.insert(tab.id).inserted && !(tab.agentSession?.session.map(sessions.contains) ?? false) && needsInput(tab)
        }
        return waiting.map(Target.chat) + blocked.map { .tab($0.id) }
    }

    /// `StatusMapping.needsInput`: an acpmux turn or an OSC 7501 program waits for the person.
    private static func waits(_ tab: TabModel) -> Bool { StatusMapping.shared.needsInput(tab) }

    /// Every tab of `store`'s tree, in tree order: the tabs the menu bar counts and the action visits.
    public static func tabs(of store: DaemonStore) -> [TabModel] {
        store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
    }

    /// The target the next run opens, recorded as opened; nil when nothing waits.
    public func next() -> Target? {
        let targets = Self.targets(chats: chats, tabs: tabs(), needsInput: needsInput)
        guard let key = AgentPriorityRanking.next(after: last, in: targets.map(\.key)) else {
            last = nil
            return nil
        }
        last = key
        return targets.first { $0.key == key }
    }

    /// Binds the action into `registry` (it holds this jump); `open` shows a chat, `reveal` a tab.
    public func bind(into registry: ActionRegistry, open: @escaping @MainActor (AgentActivityLane) -> Void,
                     reveal: @escaping @MainActor (String) -> Void) {
        registry.bindEffect(Self.action, effect: { [self] _ in
            guard ActionRunScope.viewChangeAllowed() else { return .done }
            switch next() {
            case .chat(let lane)?: open(lane)
            case .tab(let id)?: reveal(id)
            case nil: return .refused(Self.noneWaiting, quiet: true)
            }
            return .done
        })
    }

    static var noneWaiting: String {
        String(localized: "agent.needsInput.none", defaultValue: "No agent is waiting for input", bundle: .module)
    }
}
