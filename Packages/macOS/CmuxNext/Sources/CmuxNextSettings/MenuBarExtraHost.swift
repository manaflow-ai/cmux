public import AppKit
public import CmuxNextActions

/// What the menu bar item reads from the App each time its menu opens (``MenuBarExtra``): Computer
/// Use, the Unread and Running chats, the account, the agents, the updater and the global key
/// setting. Read only on open, so the item costs nothing while the menu is closed.
@MainActor
public protocol MenuBarExtraHost: AnyObject {
    /// The signed-in cmux account, nil when signed out.
    var menuBarAccount: MenuBarMenuState.Account? { get }
    /// The signed-in account's picture at menu row size, nil without one.
    var menuBarAvatar: NSImage? { get }
    /// This Mac's tabs whose agent runs a turn.
    var menuBarAgentsWorking: Int { get }
    /// Tabs whose agent waits on the person.
    var menuBarAgentsNeedingInput: Int { get }
    /// A downloaded update waits for Restart to Update.
    var menuBarUpdateReady: Bool { get }
    /// `app.globalHotKey` is on.
    var menuBarShowsGlobalKey: Bool { get }
    /// Computer Use is on and its helper answered: the menu shows its row.
    var menuBarComputerUseAvailable: Bool { get }
    /// The newest live Computer Use session, asked of the CUA host; nil for none or no answer.
    func menuBarComputerUseSession() async -> MenuBarMenuState.ComputerUse.Session?
    /// Takes Computer Use session `id` over (`paused`) or hands it back.
    func menuBarSetComputerUsePaused(_ id: String, _ paused: Bool) async throws
    /// The agent chats with a result nobody has read, newest first, from the unread index.
    var menuBarUnread: [MenuBarMenuState.Chat] { get }
    /// The agent chats running a turn, newest first, from the working index.
    var menuBarRunning: [MenuBarMenuState.Chat] { get }
    /// A chat row's harness mark at menu row size.
    func menuBarChatImage(_ chat: MenuBarMenuState.Chat) -> NSImage?
    /// Opens the chat (an acpmux session id) in its workspace, as its sidebar row does.
    func menuBarOpenChat(_ id: String)
}
