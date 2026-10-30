public import CmuxNextDaemon

/// What Share with Guest needs from the app (design chat-multiplayer.md 1 and 6): the chat tabs a
/// run can name, the daemon each lives on, the owner's cmux install token and where a person's run
/// says the link was copied. The App conforms with one-line forwards (`AppServices+AgentShareHost`).
@MainActor
public protocol AgentShareHost: AnyObject {
    /// The tab on this Mac's daemon surface `surface`.
    func shareTab(surface: SurfaceID) -> TabModel?
    /// The tab with id or resource id `id`, on any machine.
    func shareTab(id: String) -> TabModel?
    /// The id of the tab that shows acpmux session `session` (the chat whose agent ran the CLI).
    func shareTabID(showing session: String) -> String?
    /// The id of the focused pane's selected tab.
    var shareFocusedTabID: String? { get }
    /// The connection of the daemon that holds `tab`; nil when that machine is not connected.
    func shareConnection(holding tab: TabModel) -> DaemonConnection?
    /// Whether `tab` is on this Mac's daemon, the only one that makes and lists shares.
    func shareIsOnThisMac(_ tab: TabModel) -> Bool
    /// This Mac's daemon connection (list, revoke and kick act on this Mac's shares).
    var shareLocalConnection: DaemonConnection? { get }
    /// A fresh cmux install token of the signed-in owner (`/v1/auth/token`, ES256); nil signed out.
    func shareOwnerToken() async -> String?
    /// Puts `text` on the general pasteboard.
    func shareCopy(_ text: String)
    /// Shows a person's run `message` as a notice in the active window.
    func shareNotice(_ message: String)
}
