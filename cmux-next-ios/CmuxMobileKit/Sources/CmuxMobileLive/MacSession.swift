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
    /// This Mac link's last progress (Rust `LinkProgressClock`): bytes heard on any channel, a
    /// write taken, the link reaching a step. Every send-path wait on this Mac is bounded by
    /// silence on it, not by a fixed time (Leo, 2026-11-24: "if it's making good progress, it
    /// shiukd be allowed to keep going?").
    let progress = LinkProgress()
    /// Separate ACP clients: VM-local session ids never collide with this Mac's.
    var cloudChats: [String: CloudChatRelay] = [:]
    let feed: LiveFeed
    let terminalFeed: TerminalFeed
    #if canImport(CmuxMobileLinkFFI)
    /// Keys typed from the Feed, held until the Mac has them (``TerminalKeyOutbox``).
    let terminalKeys = TerminalKeyOutbox()
    #endif
    /// The Mac app's own Feed requests (held PRs, sign-ins, consent cards).
    let needsYou: MacNeedsYouFeed
    /// Workspace and tab changes on this Mac.
    let creation: LiveWorkspaceCreationBackend

    /// The last tree this Mac sent.
    var tree: DaemonTree?
    /// The acpmux sessions' open asks go to the workspace rows at the next display frame
    /// (`LiveCoordinator.wire`): one mapping per frame, not per watch event.
    var pendingSyncScheduled = false
    /// The chats the next pending sync maps: only the ones a watch event changed, or every chat
    /// (nil) once a whole list arrived.
    private var pendingSyncIDs: Set<String>? = []
    /// Runs the pending sync at the next display frame (tests run it by hand).
    var nextFrame: @MainActor (@escaping @MainActor () -> Void) -> Void = NextDisplayFrame.schedule
    /// Pending syncs run (tests: one a frame, however many watch events the frame brought).
    private(set) var pendingSyncs = 0
    /// The link to this Mac (identity: a newer link replaces it).
    var currentLink: (any MacLink)?
    /// `currentLink` once its `auth` channel opened (at once without pairing keys): what
    /// terminal tabs, files, uploads and browser tabs open their channels on, so none of
    /// them reaches the Mac ahead of `auth` (hostd refuses those `unpaired`).
    var servedLink: (any MacLink)? {
        // The attachment queue follows the served link: an upload waiting for
        // this Mac goes on from its last acked byte on the next one.
        didSet { if servedLink !== oldValue { AttachmentUploadClient.shared.setLink(macID: macID, link: servedLink) } }
    }
    /// The pairing run on a link: input-lane channels (another stream, which can
    /// overtake `auth`) wait for it (review m6), and Retry re-runs a refused one (M2).
    var pairingGate: (link: any MacLink, passed: Task<Bool, Never>)?
    var pairingState: LinkPairing.State = .idle
    /// The phone's own next pairing attempt after a refusal (``LinkPairing/retryDelay(after:attempt:)``),
    /// and how many ran since this Mac last paired.
    var pairingRetry: Task<Void, Never>?
    var pairingRetries = 0
    /// Terminal tabs of this Mac handed out, reattached on every new link.
    var terminals: [WeakTerminal] = []
    /// Whether this Mac's terminal tabs say it is offline (termfix-r13 D4).
    var terminalsOffline = false
    /// How long this link has been down as the person saw it (``LinkOutageClock``).
    var outage = LinkOutageClock()
    /// When this link last stopped being connected, or the app came back while it was down
    /// (nil: connected or idle).
    var linkDownSince: ContinuousClock.Instant? { outage.since }
    var offlineTask: Task<Void, Never>?
    /// Shows the header's "Offline" once the link has been down for the quiet bound.
    var quietStatusTask: Task<Void, Never>?
    /// Looks again when a redial reaches ``LiveCoordinator/macStallAfter`` (cmux#52200).
    var stallTask: Task<Void, Never>?
    /// Why the chat (acpmux) channel failed on the current link, shown in the status line.
    var chatsError: String?
    /// The chats channel bound again by itself after it failed on a link that stayed up (bounded,
    /// `RetryBounds.chatsRebindDelay`); a newer link or a bind that succeeds ends it.
    var chatsRebind: Task<Void, Never>?
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
        needsYou = MacNeedsYouFeed(store: feedStore)
        creation = LiveWorkspaceCreationBackend(sync: workspaces, link: link, acpmux: nil)
        feed.hub = acpmux
        acpmux.linkProgress = progress
        feed.terminal = terminalFeed
        creation.attach(acpmux: acpmux)
    }

    /// Maps the sessions' asks and titles into the workspace rows at the next display frame,
    /// once however many watch events the frame brought (each one mapped them, on the main
    /// thread, while a busy Mac's agents streamed). `chats`: the chats the event changed (one
    /// chat's event updates that chat's entries); nil: every chat (a whole list arrived).
    func schedulePendingSync(chats ids: Set<String>? = nil) {
        if let ids {
            pendingSyncIDs?.formUnion(ids)
        } else {
            pendingSyncIDs = nil
        }
        guard !pendingSyncScheduled else { return }
        pendingSyncScheduled = true
        nextFrame { [weak self] in
            guard let self else { return }
            pendingSyncScheduled = false
            pendingSyncs += 1
            let ids = pendingSyncIDs
            pendingSyncIDs = []
            guard let ids else {
                workspaces.setPending(acpmux.sessions.mapValues { $0.pendingPermissions > 0 },
                                      waitingFor: feed.waitingFor,
                                      chatTitles: acpmux.sessions.compactMapValues(\.title))
                return
            }
            // Each chat as it is now (nil: it went); every other chat's entry stands.
            var rows: [String: AcpmuxSession?] = [:]
            for id in ids { rows[id] = .some(acpmux.sessions[id]) }
            workspaces.setPending(rows: rows, waitingFor: feed.waitingFor)
        }
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
