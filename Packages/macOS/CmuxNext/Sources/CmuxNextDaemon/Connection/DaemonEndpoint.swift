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
public enum DaemonCapabilities {
    public static let required: [String] = [
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
    public static let workspaceGroups = "workspace-groups-v1"
    public static let workspaceMetadata = "workspace-metadata-v1"
    public static let tabMetadata = "tab-metadata-v1"
    public static let frontendBrowserTabs = "frontend-browser-tabs-v1"
    public static let tabDrag = "tab-drag-v1"
    public static let notificationAck = "notification-ack-v1"
    public static let tabGroups = "tab-groups-v1"
    public static let savedTabGroups = "saved-tab-groups-v1"
    /// Screen color, icon, pin, and order (`set-screen-metadata`, `set-screen-pinned`, `move-screen`).
    public static let screenMetadata = "screen-metadata-v1"
    /// Screen groups and saved screen groups.
    public static let screenGroups = "screen-groups-v1"
    /// Per-terminal `env` on `new-tab`, `split`, `create-terminal`; `cwd` on `split`.
    public static let terminalEnv = "terminal-env-v1"
    /// Caller-chosen `terminal_id` on `new-tab`, `split`, `new-pane`, and
    /// `new-pane-right`; `cwd`/`env` on the last two (cmux-tui PR 15600).
    public static let terminalPlacementEnv = "terminal-placement-env-v1"
    /// The owner ends a terminal with no tab after a grace period unless it
    /// is kept: `keep` on creation, `set-terminal-keep`, and
    /// `shutdown-daemon end_terminals` (cmux-tui PR 15600).
    public static let terminalReap = "terminal-reap-v1"
    /// `close-tabs` and `end_terminals` on the container closes: many tabs and
    /// the terminals they end close in one daemon commit.
    public static let batchClose = "batch-close-v1"
    /// Browser tabs reach the machine's loopback services over a dedicated
    /// connection (`LoopbackForwardClient`, plans/cmux-next/remote-localhost.md).
    public static let loopbackForward = "loopback-forward-v1"
    /// Profiles (plans/cmux-next/data-model.md): the `*-profile` commands,
    /// `move-workspace-to-profile`, `profiles` in `list-workspaces`, and a
    /// `profile` field on workspaces, groups and saved tab groups.
    public static let profiles = "profiles-v1"
    /// Personal state kept only on the home (local) session
    /// (plans/cmux-next/data-model.md): a remote daemon never needs these.
    public static let homeOnly: [String] = [profiles]
    /// Written to the local daemon's personal rows instead of each machine's
    /// daemon once the local daemon serves `profiles-v1`.
    public static let personalOnHome: [String] = [workspaceGroups, savedTabGroups]
    public static let optional: [String] = [workspaceGroups, workspaceMetadata, tabMetadata, frontendBrowserTabs, tabDrag,
                                            notificationAck, tabGroups, savedTabGroups, terminalEnv, terminalPlacementEnv,
                                            terminalReap, batchClose, loopbackForward]

    /// Capabilities the app already speaks but the pinned cmux-tui does not
    /// serve yet. They are advertised, so a daemon that has them enables them,
    /// but they are not in `optional` (the pinned daemon must serve every
    /// `optional` capability, BranchDaemonTests). The pin commit that brings
    /// one moves it into `optional`.
    public static let awaitingPin: [String] = [profiles, screenMetadata, screenGroups]

    /// Echoed through `set-client-info` so the daemon enables additive shapes.
    public static let advertised: [String] = required + optional + awaitingPin + [
        "attach-identity-v1",
        "creation-receipts-v1",
        "creation-attempt-keys-v1",
        "terminal-color-overrides-v1",
    ]
}
