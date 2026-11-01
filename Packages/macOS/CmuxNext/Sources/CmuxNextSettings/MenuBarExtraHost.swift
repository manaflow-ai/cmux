public import AppKit
public import CmuxNextActions

/// What the menu bar item reads from the App each time its menu opens (``MenuBarExtra``): the
/// account, the agents, the updater and the global key setting. Read only on open, so the item
/// costs nothing while the menu is closed.
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
}
