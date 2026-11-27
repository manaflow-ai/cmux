public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextTabs

/// What a sidebar chat move needs from the app (`AppServices`): the row's workspace, which of its tabs are chats, and
/// the chat's Move to… (its targets, and the move itself).
@MainActor
public protocol ChatMoveHost: AnyObject {
    /// The workspace of sidebar row `id`.
    func chatMoveWorkspace(_ id: String) -> WorkspaceModel?
    /// The machine that workspace is on (its daemon's machine id).
    func chatMoveMachine(ofWorkspace id: String) -> String?
    func isChat(_ tab: AgentTabKey) -> Bool
    /// The chat's Move to… targets: machine ids as the sidebar names machines (`local`, a Cloud machine's id).
    func chatMoveTargets(_ tab: AgentTabKey) -> [String]
    /// Runs the chat's Move to… to `machine`; false when it was refused (it says why).
    func moveChat(_ tab: AgentTabKey, to machine: String) -> Bool
}

/// A visible move between machines (Leo, 2026-11-19): a chat's row dropped on another machine in the sidebar (its
/// group header, or a slot among its rows) moves the chat there through its Move to…. The sidebar's drag offers such
/// a slot only for the machines ``targets(of:)`` names (Rust `sidebar_drop` `move_to`); the move then shows on the
/// row (`SidebarChatMove`).
@MainActor
public struct ChatMoveDrop {
    public let host: any ChatMoveHost

    public init(host: any ChatMoveHost) { self.host = host }

    /// Nil when `intent` is no chat move (the bridge goes on as before: a non-chat row dropped on another machine
    /// snaps back); true when the move started, false when it was refused (the bridge shows the rows again).
    public func drop(_ intent: SidebarIntent) -> Bool? {
        guard case let .reorder(ids, position) = intent, ids.count == 1, let id = ids.first,
              case let .machine(machine) = position.section,
              let (chat, from) = chat(of: id), from != machine.rawValue,
              host.chatMoveTargets(chat).contains(machine.rawValue) else { return nil }
        return host.moveChat(chat, to: machine.rawValue)
    }

    /// The machines row `id`'s chat can move to (`SidebarModel.chatMoveTargets`); none for a row with no chat or several.
    public func targets(of id: WorkspaceID) -> [MachineID] {
        chat(of: id).map { host.chatMoveTargets($0.0).map(MachineID.init) } ?? []
    }

    /// Row `id`'s one chat tab and the machine it is on.
    private func chat(of id: WorkspaceID) -> (AgentTabKey, String)? {
        guard let workspace = host.chatMoveWorkspace(id.rawValue), let machine = host.chatMoveMachine(ofWorkspace: id.rawValue) else { return nil }
        let chats = workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { AgentTabKey(machine: machine, key: $0.id) }.filter(host.isChat)
        guard chats.count == 1, let chat = chats.first else { return nil }
        return (chat, machine)
    }
}
