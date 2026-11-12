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
    /// Computer Use is on and cmux Remote's worker runs: the menu shows its row.
    var menuBarComputerUseAvailable: Bool { get }
    /// The agent sessions cmux Remote's worker reports (who acts, on which app), newest action
    /// first: what the app already holds from the daemon's `computer-use-activity`, no request.
    var menuBarComputerUseSessions: [MenuBarMenuState.ComputerUse.Session] { get }
    /// The agent chats with a result nobody has read, newest first, from the unread index.
    var menuBarUnread: [MenuBarMenuState.Chat] { get }
    /// The agent chats running a turn, newest first, from the working index.
    var menuBarRunning: [MenuBarMenuState.Chat] { get }
    /// A chat row's harness mark at menu row size.
    func menuBarChatImage(_ chat: MenuBarMenuState.Chat) -> NSImage?
    /// Opens the chat (an acpmux session id) in its workspace, as its sidebar row does.
    func menuBarOpenChat(_ id: String)
    /// Lets Computer Use session `session`, which the person stopped, act again (the menu's Resume).
    func menuBarResumeComputerUse(_ session: String)
    /// Rings Computer Use session `session`'s agent cursor where it is (the menu's Show Cursor).
    func menuBarShowComputerUseCursor(_ session: String)
}
