import Foundation

public enum DaemonEvent: Sendable, Hashable {
    // Connection lifecycle, synthesized by `DaemonConnection`.

    /// A (re)connect finished the handshake and the subscription is live.
    /// Fetch `list-workspaces` now. `generationChanged` means every numeric
    /// handle from before is invalid and attachments must be re-created.
    case connected(DaemonIdentity, generationChanged: Bool)
    /// The socket dropped. The connection retries on its own.
    case disconnected(reason: String)

    // Tree deltas (`tree_events:"deltas"`).
    case workspaceAdded(WorkspaceDelta)
    case workspaceClosed(WorkspaceDelta)
    case workspaceRenamed(WorkspaceDelta)
    case workspaceMoved(WorkspaceDelta)
    /// Color/icon/title changed (`workspace-metadata-v1`); revisioned.
    case workspaceChanged(WorkspaceDelta)
    case screenAdded(ScreenDelta)
    case screenClosed(ScreenDelta)
    case screenRenamed(ScreenDelta)
    /// Color, icon, pin, group, or order changed (`screen-metadata-v1`); not revisioned.
    case screenChanged(ScreenDelta)
    case paneAdded(PaneDelta)
    case paneClosed(PaneDelta)
    case tabAdded(TabDelta)
    case tabClosed(TabDelta)
    case tabRenamed(TabDelta)
    /// Pin, cwd/git, or unread marker changed (`tab-metadata-v1`); not revisioned.
    case tabChanged(TabDelta)
    /// Full resync barrier: refetch `list-workspaces`. `transaction` echoes
    /// the client transaction id of the command that caused it, when any.
    case treeChanged(transaction: ClientTransactionID?)
    /// Personal state (`profiles-v1`) changed: the store refetches `list-personal` alone, never the
    /// tree (a sidebar group's fold writes `personal_groups`; plans/cmux-next/state-ownership-DESIGN.md).
    case personalChanged
    /// Pane geometry changed on a screen. With `layout-delta-v1` it carries
    /// the screen's new layout, which patches that screen; without one
    /// (an older daemon) the store refetches.
    case layoutChanged(screen: ScreenID, layout: ScreenLayoutDelta?, transaction: ClientTransactionID?)

    // Surface state.
    case titleChanged(surface: SurfaceID, title: String)
    case surfaceResized(surface: SurfaceID, size: CellSize)
    case surfaceExited(surface: SurfaceID)
    case scrollChanged(surface: SurfaceID, offset: UInt64, atBottom: Bool)
    case bell(surface: SurfaceID)
    case notification(DaemonNotification)
    case agentChanged(AgentStatus)
    /// What a surface's agent is touching now (`agent-presence-v1`).
    case agentPresenceChanged(AgentPresence)

    /// A `session.events` item: the state resources the daemon owns
    /// (state-ownership.md 2), which `DaemonStore.session` mirrors.
    case sessionState(SessionStreamItem)

    // Registries and clients.
    case frontendProjectionChanged(ProjectionChange)
    case terminalRegistryChanged(revision: UInt64)
    /// A browser profile's bookmarks changed (`bookmarks-v1`): refetch them.
    case bookmarksChanged(browserProfileID: String, revision: UInt64)
    /// The daemon history module committed a change (`history-v1`): its revision and the entry
    /// kinds it touched. History views re-read `history.entries.list`.
    case historyChanged(revision: UInt64, kinds: [String])
    /// keybindings.json changed (`keybindings-v1`): a hand edit or a write.
    case keybindingsChanged(revision: UInt64)
    /// One committed op on a local conversation (`local-conversations-v1`).
    case conversationChanged(ConversationEvent)
    /// A participant started or stopped typing (ephemeral).
    case conversationTyping(ConversationTyping)
    /// The running reply of an agent participant (ephemeral).
    case conversationDraft(ConversationDraft)
    /// A Chief's live run frame (`chief-live-v1`, ephemeral): reply text so far and its activity line.
    case conversationLive(ConversationLive)
    /// A local run after an append (`conversation-runs-v1`): its status ends live text.
    case conversationRunChanged(ConversationRunChanged)
    /// A `cloud-*` event of `cloud-conversations-v1` (cloud conversations,
    /// the account inbox, socket states and lease requests).
    case cloudConversations(CloudConversationsEvent)
    /// `terminal-clipboard-read` (targeted at this connection): a program asks
    /// for the clipboard (`TerminalClipboardBroker`).
    case terminalClipboardRead(TerminalClipboardRead)
    /// `terminal-clipboard-read-cancelled`: that read ended unanswered.
    case terminalClipboardReadCancelled(requestID: String)
    /// `client-attached/changed/detached/list-invalidated`.
    case client(name: String, payload: JSONValue)
    /// The subscription ended because this client fell behind. The connection
    /// resubscribes; treat it like `treeChanged`.
    case overflow(String)
    case daemonShutdown
    case unknown(name: String, payload: JSONValue)
}

extension DaemonEvent {
    /// Applies even when a tree snapshot covers its sequence: connection
    /// lifecycle, `session.events` items and the app supervisor's events,
    /// which `list-workspaces` does not carry.
    var outlivesSnapshot: Bool {
        switch self {
        case .connected, .disconnected, .daemonShutdown, .sessionState: true
        // Transient questions to this connection; a snapshot never holds them.
        case .terminalClipboardRead, .terminalClipboardReadCancelled: true
        // Terminal outcomes live outside list-workspaces, including background jobs.
        case .terminalRegistryChanged: true
        // Agent state and presence are not in the tree snapshot (only `list-agents` at connect
        // and these events carry them). A blocked hook also posts a notification, whose tree
        // change resyncs; dropping its `agent-changed` behind that snapshot left the row on
        // "working" (cx-ag5.6.8). Each event carries the whole state of one surface.
        case .agentChanged, .agentPresenceChanged: true
        // A notification's text is in its event alone; the snapshot has only the tab's unread
        // marker. The daemon follows each notification with `tree-changed`, so a second one often
        // lands while that resync's snapshot is in flight, under its barrier.
        case .notification: true
        // The app supervisor's events (apps-v1): scene batches, changes and provider calls.
        // And browser pairings (cx-hnmbt.2): a dropped request would never show its Approve dialog.
        // Inventory leases have their own revision/lifecycle; a tree resync
        // cannot replace a targeted invalidation or acknowledge an ended lease.
        case .unknown(let name, _):
            DaemonSideEvents.isAppsEvent(name) || name.hasPrefix("pairing-")
                || name == "agent-inventory-changed" || name == "agent-inventory-watch-ended"
        default: false
        }
    }
}
