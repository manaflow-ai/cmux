import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextDesign
import CmuxNextSidebar

/// A Priority row's actions on its chat (an `agent-chat:` target): Mark Chat as Read…, Pin/Unpin Chat in Priority…,
/// Snooze Chat for 1 Hour…, Move Chat Earlier/Later in Priority… (the palette asks which chat), and Archive Chat. The
/// row's hover buttons, its right-click menu (`ActionMenuContext.priorityRow`), the palette and a user's shortcut all
/// run them through the registry, and they write the marks through `AgentPriorityChats`.
@MainActor
struct SidebarPriorityRowActions {
    static let markRead: ActionID = "sidebar.priority.markRead"
    static let togglePin: ActionID = "sidebar.priority.togglePin"
    static let snooze: ActionID = "sidebar.priority.snooze"
    /// A row's archive is Archive Chat on the row's chat, not an action of its own.
    static let archive: ActionID = "agentPane.archiveChat"
    /// Restore on an archived chat (the Archived fold's rows): it lists again. Its menu row shows only for an archived chat,
    /// whose menu leaves out Pin, Snooze and Archive.
    static let restore: ActionID = "sidebar.priority.restore"

    let chats: AgentPriorityChats
    /// Why the row actions cannot run now (the view is off); nil while they can.
    var unavailable: @MainActor () -> String? = { nil }
    /// Where an archive's Undo toast shows (toasts v2): the app's active window. Nil: no toast.
    var toastWindow: @MainActor () -> NSWindow? = { nil }
    /// The presenter; its ``CmuxToastCenter/v2`` decides whether an archive offers Undo (tests pass their own).
    var toasts: CmuxToastCenter = .shared

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

    /// A row button's action and chat; nil for the view's own choices (open, fold, bell, drag, answer).
    static func route(_ action: SidebarPriorityAction) -> (ActionID, String)? {
        switch action {
        case .markRead(let id): (Self.markRead, id)
        case .togglePin(let id): (Self.togglePin, id)
        case .snooze(let id): (Self.snooze, id)
        case .archive(let id): (Self.archive, id)
        case .restore(let id): (Self.restore, id)
        case .open, .setCollapsed, .toggleShown, .place, .answer, .setFilter, .markAllRead, .openArchived, .setArchivedFolded,
             .showMoreArchived: nil
        }
    }

    /// Runs a row button's action through the registry, as its menu row does.
    static func perform(_ action: SidebarPriorityAction, in registry: ActionRegistry) {
        guard let (id, chat) = route(action) else { return }
        // Restore is new to the Rust action catalog; until the app's pinned FFI catalog lists it
        // (docs/ci/app-ffi-release.md), the Archived fold's button restores straight through the chats.
        if id == Self.restore, registry.action(for: id) == nil {
            _ = AgentPriorityChats.app.restore(chat)
            return
        }
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
        for (id, step) in [("sidebar.priority.moveEarlier", -1), ("sidebar.priority.moveLater", 1)] as [(ActionID, Int)] { registry.bind(id, unavailable: unavailable, run: { try Self.run({ chats.move($0, by: step) }, $0) }) }
        // Only a result or a failure is read: the menu leaves the row out where the button greys.
        ActionTargetVisibility.hide(Self.markRead, in: registry) { invocation in
            Self.chat(invocation).flatMap { chats.entry($0) }?.canMarkRead != true
        }
        // The menu row says what it does to this chat, as the pin button does.
        ActionTargetTitles.set(Self.togglePin, in: registry) { invocation in
            Self.chat(invocation).flatMap { chats.entry($0) }?.pinTitle
        }
        // Restore runs on any surface for an archived chat; the Priority view being off does not stop it (the chat
        // lists again wherever it listed). An archived chat's menu is Restore, not the ranked rows' actions.
        registry.bindEffect(Self.restore, effect: { Self.chat($0).map(chats.restore) == true ? .done : .refused(SidebarSectionStrings.noSuchPriorityChat) })
        ActionTargetVisibility.hide(Self.restore, in: registry) { invocation in
            Self.chat(invocation).map { !chats.isArchived($0) } ?? true
        }
        for id in [Self.togglePin, Self.snooze] {
            ActionTargetVisibility.hide(id, in: registry) { invocation in Self.chat(invocation).map(chats.isArchived) ?? false }
        }
    }

    /// Binds Archive Chat: a row's chat archives here (hidden at once, then archived in its acpmux)
    /// and, like the other row actions, not while `unavailable` gives a reason; any other run is the
    /// focused chat's own Archive (`otherwise`), which the Priority view's setting does not touch.
    func bindArchive(into registry: ActionRegistry, otherwise: @escaping @MainActor (ActionInvocation) throws -> Void) {
        let chats = chats, unavailable = unavailable, toasts = toasts, toastWindow = toastWindow
        registry.bind(Self.archive, run: { invocation in
            guard invocation.target?.kind == .agentChat else { return try otherwise(invocation) }
            // Toasts v2: the archive offers Undo, which unarchives the chat. Off: the archive alone.
            try Self.run({ toasts.v2 ? chats.archive($0, undo: toasts, in: toastWindow(), message: SidebarSectionStrings.archivedChat) : chats.archive($0) },
                         invocation)
        })
        ActionTargetReasons.set(Self.archive, in: registry) { invocation in
            invocation.target?.kind == .agentChat ? unavailable() : nil
        }
        // An archived chat's row (the Archived fold) offers Restore instead.
        ActionTargetVisibility.hide(Self.archive, in: registry) { invocation in
            invocation.target?.kind == .agentChat && Self.chat(invocation).map(chats.isArchived) == true
        }
    }

    private static func run(_ change: (String) -> Bool, _ invocation: ActionInvocation) throws {
        guard let id = chat(invocation), change(id) else { throw ActionFailure.invalidTarget(SidebarSectionStrings.noSuchPriorityChat) }
    }
}
