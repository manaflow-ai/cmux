import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextPalette
import CmuxNextSidebar

extension AgentPriorityChats {
    /// The app's Priority chats: this Mac's acpmux and the Chief home's, archived over their sockets.
    @MainActor static let app = makeApp()

    // A function, not the property's initial value: the archive closure is nonisolated, the stores main-actor.
    private static func makeApp() -> AgentPriorityChats {
        AgentPriorityChats(marks: .shared, stores: [.shared, .chief],
                           archive: { try await AcpmuxChatArchive(socketPath: $0).archive(sessionId: $1) })
    }
}

/// A Priority row's actions on its chat (an `agent-chat:` target): Mark Chat as Read…, Pin/Unpin
/// Chat in Priority…, Snooze Chat for 1 Hour… (the palette asks which chat), and Archive Chat. The
/// row's hover buttons, its right-click menu (`ActionMenuContext.priorityRow`), the palette and a
/// user's shortcut all run them through the registry, and they write the marks through
/// `AgentPriorityChats`.
@MainActor
struct SidebarPriorityRowActions {
    static let markRead: ActionID = "sidebar.priority.markRead"
    static let togglePin: ActionID = "sidebar.priority.togglePin"
    static let snooze: ActionID = "sidebar.priority.snooze"
    /// A row's archive is Archive Chat on the row's chat, not an action of its own.
    static let archive: ActionID = "agentPane.archiveChat"

    let chats: AgentPriorityChats
    /// Why the row actions cannot run now (the view is off); nil while they can.
    var unavailable: @MainActor () -> String? = { nil }

    /// Why the row actions cannot run in the app: the Priority view is off (`SidebarPriorityFeed`
    /// binds the other three with the same check).
    static func viewOff(_ context: AppActionContext) -> @MainActor () -> String? {
        {
            let preferences = context.services.settings?.snapshot.sidebarSections ?? .defaults
            return preferences.priorityViewEnabled ? nil : SidebarPriorityPanel.unavailableReason
        }
    }

    /// The target a hover button and the row's menu pass.
    static func target(_ chat: String) -> ActionTargetRef { ActionTargetRef(kind: .agentChat, id: chat) }

    /// A row button's action and chat; nil for the view's own choices (open, fold, bell, drag).
    static func route(_ action: SidebarPriorityAction) -> (ActionID, String)? {
        switch action {
        case .markRead(let id): (Self.markRead, id)
        case .togglePin(let id): (Self.togglePin, id)
        case .snooze(let id): (Self.snooze, id)
        case .archive(let id): (Self.archive, id)
        case .open, .setCollapsed, .toggleShown, .place: nil
        }
    }

    /// Runs a row button's action through the registry, as its menu row does.
    static func perform(_ action: SidebarPriorityAction, in registry: ActionRegistry) {
        guard let (id, chat) = route(action) else { return }
        registry.perform(id, invocation: ActionInvocation(target: target(chat), origin: .user))
    }

    /// The chat a run names: its `agent-chat:` target, or the chat the palette picked.
    static func chat(_ invocation: ActionInvocation) -> String? {
        if let target = invocation.target, target.kind == .agentChat { return target.id }
        return invocation.arguments["chat"]?.targetValue?.id
    }

    func bind(into registry: ActionRegistry) {
        let chats = chats
        registry.bind(Self.markRead, unavailable: unavailable, run: { try Self.run(chats.markRead, $0) })
        registry.bind(Self.togglePin, unavailable: unavailable, run: { try Self.run(chats.togglePin, $0) })
        registry.bind(Self.snooze, unavailable: unavailable, run: { try Self.run({ chats.snooze($0) }, $0) })
        // Only a result or a failure is read: the menu leaves the row out where the button greys.
        ActionTargetVisibility.hide(Self.markRead, in: registry) { invocation in
            Self.chat(invocation).flatMap { chats.entry($0) }?.canMarkRead != true
        }
        // The menu row says what it does to this chat, as the pin button does.
        ActionTargetTitles.set(Self.togglePin, in: registry) { invocation in
            Self.chat(invocation).flatMap { chats.entry($0) }?.pinTitle
        }
    }

    /// Binds Archive Chat: a row's chat archives here (hidden at once, then archived in its acpmux)
    /// and, like the other row actions, not while `unavailable` gives a reason; any other run is the
    /// focused chat's own Archive (`otherwise`), which the Priority view's setting does not touch.
    func bindArchive(into registry: ActionRegistry, otherwise: @escaping @MainActor (ActionInvocation) throws -> Void) {
        let chats = chats, unavailable = unavailable
        registry.bind(Self.archive, run: { invocation in
            guard invocation.target?.kind == .agentChat else { return try otherwise(invocation) }
            try Self.run(chats.archive, invocation)
        })
        ActionTargetReasons.set(Self.archive, in: registry) { invocation in
            invocation.target?.kind == .agentChat ? unavailable() : nil
        }
    }

    private static func run(_ change: (String) -> Bool, _ invocation: ActionInvocation) throws {
        guard let id = chat(invocation), change(id) else { throw ActionFailure.invalidTarget(SidebarSectionStrings.noSuchPriorityChat) }
    }
}

/// The palette's list of Priority chats for a row action's `chat` argument, in rank order. Other
/// kinds fall through to `next`.
final class PriorityChatTargetSource: PaletteTargetSource {
    private let chats: AgentPriorityChats
    private let next: any PaletteTargetSource

    init(chats: AgentPriorityChats, next: any PaletteTargetSource) {
        self.chats = chats
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        guard kind == .agentChat else { return next.targets(of: kind) }
        return chats.entries().map { entry in
            let place = [entry.project, entry.machine].compactMap(\.self).joined(separator: " · ")
            return PaletteTargetOption(id: entry.id, title: entry.title, subtitle: place.isEmpty ? nil : place, symbol: "bubble.left")
        }
    }

    func title(of target: ActionTargetRef) -> String? {
        guard target.kind == .agentChat else { return next.title(of: target) }
        return chats.entry(target.id)?.title
    }

    func currentDescription(of target: ActionTargetRef) -> String? {
        next.currentDescription(of: target)
    }
}
