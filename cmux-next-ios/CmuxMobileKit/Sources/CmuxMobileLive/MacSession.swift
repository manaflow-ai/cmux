#if os(iOS)
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation

/// One Mac's link and everything served on it: its own `LinkController`
/// (dial, retry, TURN path, heartbeat, transport), its workspace list, its
/// acpmux chats, its Feed items and its terminal tabs. The coordinator keeps
/// one per Mac it links (`MacLinkPolicy`), so two Macs work at once
/// (PROTOCOL.md "One link per Mac"). Nothing here reaches another Mac's link.
@MainActor
final class MacSession {
    let macID: String
    var name: String
    let link: LinkController
    let workspaces: WorkspaceSync
    let acpmux = AcpmuxHub()
    /// Separate ACP clients: VM-local session ids never collide with this Mac's.
    var cloudChats: [String: CloudChatRelay] = [:]
    let feed: LiveFeed
    let terminalFeed: TerminalFeed
    /// Workspace and tab changes on this Mac.
    let creation: LiveWorkspaceCreationBackend

    /// The last tree this Mac sent.
    var tree: DaemonTree?
    /// The link to this Mac (identity: a newer link replaces it).
    var currentLink: (any MacLink)?
    /// `currentLink` once its `auth` channel opened (at once without pairing keys): what
    /// terminal tabs, files, uploads and browser tabs open their channels on, so none of
    /// them reaches the Mac ahead of `auth` (hostd refuses those `unpaired`).
    var servedLink: (any MacLink)?
    /// The pairing run on a link: input-lane channels (another stream, which can
    /// overtake `auth`) wait for it (review m6), and Retry re-runs a refused one (M2).
    var pairingGate: (link: any MacLink, passed: Task<Bool, Never>)?
    var pairingState: LinkPairing.State = .idle
    /// Terminal tabs of this Mac handed out, reattached on every new link.
    var terminals: [WeakTerminal] = []
    /// Whether this Mac's terminal tabs say it is offline (termfix-r13 D4).
    var terminalsOffline = false
    /// When this link last stopped being connected (nil: connected or idle).
    var linkDownSince: ContinuousClock.Instant?
    var offlineTask: Task<Void, Never>?
    /// Why the chat (acpmux) channel failed on the current link, shown in the status line.
    var chatsError: String?
    var daemonError: String?
    var workspacesTimeout: Task<Void, Never>?
    /// The link fed this Mac's data and connection state (cleared when it closes).
    var fedData = false
    /// The Mac's host predates the `version` service (link protocol 1).
    var outdated = false

    struct WeakTerminal {
        weak var session: DaemonTerminalSession?
    }

    init(macID: String, name: String, link: LinkController, deviceID: String, deviceName: String, feedStore: FeedStore) {
        self.macID = macID
        self.name = name
        self.link = link
        workspaces = WorkspaceSync(deviceID: deviceID, deviceName: deviceName)
        feed = LiveFeed(store: feedStore, hub: nil, place: { _ in nil })
        feed.macID = macID.isEmpty ? nil : macID
        terminalFeed = TerminalFeed(store: feedStore)
        creation = LiveWorkspaceCreationBackend(sync: workspaces, link: link, acpmux: nil)
        feed.hub = acpmux
        feed.terminal = terminalFeed
        creation.attach(acpmux: acpmux)
    }

    /// Where an acpmux session of this Mac lives (workspace and tab).
    func place(sessionID: String) -> LiveFeed.Place? {
        guard let tree else { return nil }
        for workspace in tree.workspaces + tree.homeWorkspaces {
            for tab in workspace.tabs where tree.agentTabs[tab.id]?.session == sessionID {
                return LiveFeed.Place(workspaceID: workspace.id, tabID: tab.id, workspaceTitle: workspace.title, tabTitle: tab.title)
            }
        }
        return nil
    }
}
#endif
