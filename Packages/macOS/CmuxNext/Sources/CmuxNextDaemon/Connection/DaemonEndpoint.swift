import Foundation
import Synchronization
import os

/// Where the daemon listens, as printed by `server ensure`.
public struct DaemonEndpoint: Hashable, Sendable {
    public var socketPath: String
    public var pid: Int32?
    public var generation: DaemonGeneration?

    public init(socketPath: String, pid: Int32? = nil, generation: DaemonGeneration? = nil) {
        self.socketPath = socketPath
        self.pid = pid
        self.generation = generation
    }
}

/// Capabilities the GUI relies on (plans/cmux-next/cmux-tui-contract.md 2.2).
public struct DaemonCapabilities: Sendable {
    public static let shared = Self()
    public let required: [String] = [
        "workspace-registry-v1",
        "viewport-splits-v1",
        "viewport-column-resize-v1",
        "layout-undo-v1",
        "view-attachment-lease-v1",
        "view-attachment-detach-v1",
        "attach-initial-size",
    ]

    /// Additive protocol 12 capabilities from cmux-tui PR 15518
    /// (cmux-tui/spec/commands.md). The GUI hides the matching features when
    /// a daemon lacks them (`DaemonIdentity.supports`).
    public let workspaceGroups = "workspace-groups-v1"
    public let workspaceMetadata = "workspace-metadata-v1"
    public let tabMetadata = "tab-metadata-v1"
    public let frontendBrowserTabs = "frontend-browser-tabs-v1"
    /// A frontend browser tab's back/forward entries and scroll positions,
    /// stored opaque and outside the journal (`set-`/`get-frontend-browser-history`).
    public let frontendBrowserHistory = "frontend-browser-history-v1"
    public let tabDrag = "tab-drag-v1"
    public let notificationAck = "notification-ack-v1"
    public let tabGroups = "tab-groups-v1"
    public let savedTabGroups = "saved-tab-groups-v1"
    /// The sidebar workspace pin: `pinned` on `set-workspace-metadata` and workspaces.
    public let workspacePin = "workspace-pin-v1"
    /// The manual workspace unread mark: `marked_unread` on
    /// `set-workspace-metadata` and workspaces.
    public let notificationMarkUnread = "notification-mark-unread-v1"
    /// Screen color, icon, pin, and order (`set-screen-metadata`,
    /// `set-screen-pinned`, `move-screen`; `screen.update` and `screen.move`
    /// with `stateResources`, over the same storage).
    public let screenMetadata = "screen-metadata-v1"
    /// Screen groups and saved screen groups (`screen_group.*` with
    /// `stateResources`).
    public let screenGroups = "screen-groups-v1"
    /// The state resources over `cmux.protocol/2` (state-ownership.md steps
    /// A and B): closed history, ephemeral workspaces, workspace status,
    /// screen metadata and groups, tab records, terminal progress, and the
    /// v2 state mutations, mirrored through `session.events`. The daemon
    /// advertises it in `identify` (`DaemonStore.servesStateResources`).
    public let stateResources = "state-resources-v1"
    /// Per-terminal `env` on `new-tab`, `split`, `create-terminal`; `cwd` on `split`.
    public let terminalEnv = "terminal-env-v1"
    /// Caller-chosen `terminal_id` on `new-tab`, `split`, `new-pane`, and
    /// `new-pane-right`; `cwd`/`env` on the last two (cmux-tui PR 15600).
    public let terminalPlacementEnv = "terminal-placement-env-v1"
    /// The owner ends a terminal with no tab after a grace period unless it
    /// is kept: `keep` on creation, `set-terminal-keep`, and
    /// `shutdown-daemon end_terminals` (cmux-tui PR 15600).
    public let terminalReap = "terminal-reap-v1"
    /// `keep_layout` on `shutdown-daemon end_terminals`: every terminal ends
    /// but placed ones keep their tabs, dead, so the next launch restarts a
    /// shell in each with the same splits (Quit's End Sessions, Keep Layout).
    public let endTerminalsKeepLayout = "end-terminals-keep-layout-v1"
    /// `close-tabs` and `end_terminals` on the container closes: many tabs and
    /// the terminals they end close in one daemon commit.
    public let batchClose = "batch-close-v1"
    /// Browser tabs reach the machine's loopback services over a dedicated
    /// connection (`LoopbackForwardClient`, plans/cmux-next/remote-localhost.md).
    public let loopbackForward = "loopback-forward-v1"
    /// `source` on notifications (cli, terminal, agent, daemon), and OSC 9,
    /// OSC 777 and OSC 99 parsed by the daemon from every terminal's output
    /// (plans/cmux-next/notifications.md).
    public let notificationSource = "notification-source-v1"
    /// `shell_args` on the terminal-creating commands, so bash and nushell
    /// get Ghostty's argv-based shell integration (`GhosttyShellIntegration`).
    public let terminalShellArgs = "terminal-shell-args-v1"
    /// `launch_snapshot_path` in `identify`: the daemon's last settled tree
    /// and window records, read before connecting (`LaunchSnapshot`).
    public let launchSnapshot = "launch-snapshot-v1"
    /// Profiles (plans/cmux-next/data-model.md): the `*-profile` commands,
    /// `move-workspace-to-profile`, `profiles` in `list-workspaces`, and a
    /// `profile` field on workspaces, groups and saved tab groups.
    public let profiles = "profiles-v1"
    /// `identify.session_id` and `identify.machine_name` (data-model.md 1.1);
    /// informational, the app falls back to `registry_id` and its own names.
    public let sessionIdentity = "session-identity-v1"
    /// Remote-terminal tabs in a home layout: `new-remote-terminal-tab`,
    /// `update-remote-terminal-tab`, `remote-terminal-snapshot`, tab kind
    /// `remote-terminal` with `remote` (data-model.md 1.2b, 1.4, 1.5), and
    /// `terminal_resource_id` in the `set-terminal-keep` result.
    public let remoteTerminalTabs = "remote-terminal-tabs-v1"
    /// Sticky columns: `set-column-sticky` and `columns[].sticky`
    /// (plans/cmux-next/sticky-column.md).
    public let stickyColumns = "sticky-columns-v1"
    /// Top and bottom docks: `set-column-sticky` and `move-tab-to-column`
    /// accept edges `top` and `bottom`, sent back as `columns[].dock`
    /// (plans/cmux-next/layout-model.md).
    public let edgeDocks = "edge-docks-v1"
    /// `move-tab-to-column` `respawn`: a pane's only tab moves into a new
    /// column and leaves a fresh tab of the same kind (Dock Column on a
    /// screen with one tab).
    public let tabColumnRespawn = "tab-column-respawn-v1"
    /// `create-terminal {detached: true}`: a kept terminal with no tab.
    public let detachedTerminals = "detached-terminals-v1"
    /// Personal state kept only on the home (local) session
    /// (plans/cmux-next/data-model.md): a remote daemon never needs these.
    /// Per-terminal themes in personal state (`set-personal-terminal`).
    public let personalTerminals = "personal-terminals-v1"
    /// Browser profile records in personal state (plans/cmux-next/data-model.md 5).
    public let browserProfiles = "browser-profiles-v1"
    /// Bookmarks per browser profile in personal state (plans/cmux-next/bookmarks.md).
    public let bookmarks = "bookmarks-v1"
    /// Local conversations owned by the daemon (Home, plans/cmux-next/home.md):
    /// the `conversation-*` commands and `conversation-changed`/`conversation-typing` events.
    public let localConversations = "local-conversations-v1"
    /// `workspace.ensure_home` and the home workspace (`kind: home`; home.md 7).
    public let workspaceKind = "workspace-kind-v1"
    /// Conversation tabs: `new-conversation-tab` and the `conversation` tab kind.
    /// Echoed so the daemon sends the canonical kind instead of `browser`.
    public let conversationTabs = "conversation-tabs-v1"
    /// `conversation-search` on the local conversation owner.
    public let conversationSearch = "conversation-search-v1"
    public var homeOnly: [String] { [profiles, personalTerminals, browserProfiles, bookmarks, localConversations] }
    /// Written to the local daemon's personal rows instead of each machine's
    /// daemon once the local daemon serves `profiles-v1`.
    public var personalOnHome: [String] { [workspaceGroups, savedTabGroups] }
    /// A replay taken inside an escape sequence carries the unfinished bytes
    /// in `pending` (main PR 15533). Without it, cmux-tui ends a view's attach
    /// stream whenever a PTY resize happens mid-sequence (a relaunch resizes
    /// every restored terminal), and the view freezes.
    public let terminalPendingSequence = "terminal-pending-sequence-v1"
    /// Finished shell commands (OSC 133) journaled as `shell.command.finished`
    /// once `set-terminal-command-history` turns it on (plans/cmux-next/history.md 6).
    public let terminalCommandJournal = "terminal-command-journal-v1"
    /// `sidebar_layout.get|update` (plans/cmux-next/sidebar-sections.md 5;
    /// cmux-tui PR #16842).
    public let sidebarLayout = "sidebar-layout-v1"
    /// `move-tab-to-split` `respawn`: splitting a pane with its only tab
    /// spawns a new tab of the same kind in the source pane, in the same
    /// owner op (plans/cmux-next/layout-invariants.md).
    public let tabSplitRespawn = "tab-split-respawn-v1"
    /// Additive shapes the app asks for through `set-client-info`: view
    /// identity on attach, creation receipts, caller-chosen creation attempt
    /// keys, and per-terminal color overrides.
    public let attachIdentity = "attach-identity-v1"
    public let creationReceipts = "creation-receipts-v1"
    public let creationAttemptKeys = "creation-attempt-keys-v1"
    public let terminalColorOverrides = "terminal-color-overrides-v1"

    /// Capabilities the bundled daemon must serve. The bundled cmux-tui is
    /// built from this checkout's own cmux-tui tree
    /// (scripts/cmux-next/pin-cmux-tui.sh), and
    /// scripts/cmux-next/check-daemon-capabilities.sh fails the build when it
    /// does not serve one of these or `required`. The GUI still checks each
    /// with `DaemonIdentity.supports`, for remote and older daemons.
    public var optional: [String] { [workspaceGroups, workspaceMetadata, tabMetadata, frontendBrowserTabs, tabDrag,
                                            notificationAck, tabGroups, savedTabGroups, terminalEnv, terminalPlacementEnv,
                                            terminalReap, batchClose, loopbackForward, screenMetadata, screenGroups, profiles,
                                            terminalPendingSequence, personalTerminals, browserProfiles, notificationSource,
                                            terminalShellArgs, launchSnapshot, bookmarks, workspacePin, notificationMarkUnread,
                                            terminalCommandJournal, stickyColumns, edgeDocks, tabColumnRespawn, endTerminalsKeepLayout, stateResources,
                                            sessionIdentity, localConversations, tabSplitRespawn, frontendBrowserHistory,
                                            attachIdentity, creationReceipts, creationAttemptKeys, terminalColorOverrides,
                                            workspaceKind, conversationTabs, conversationSearch] }

    /// App code waiting for a daemon half that no branch has yet. Each
    /// feature shows disabled with its reason (or refuses with it) while the
    /// bundled daemon lacks the capability. The list only shrinks
    /// (DaemonCapabilityExportTests): new app features land with their
    /// daemon half, and check-daemon-capabilities.sh fails once the bundled
    /// daemon serves an entry, so it moves to `optional`.
    public var unservedByBundledDaemon: [String] { [remoteTerminalTabs, detachedTerminals, sidebarLayout] }

    /// Echoed through `set-client-info` so the daemon enables additive shapes.
    public var advertised: [String] { required + optional + unservedByBundledDaemon }
}
