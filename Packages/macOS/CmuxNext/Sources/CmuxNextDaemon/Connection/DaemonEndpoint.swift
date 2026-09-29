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
    /// Per-terminal `env` on `new-tab`, `split`, `create-terminal`; `cwd` on `split`.
    public static let terminalEnv = "terminal-env-v1"
    public static let optional: [String] = [workspaceGroups, workspaceMetadata, tabMetadata, frontendBrowserTabs, tabDrag,
                                            notificationAck, tabGroups, savedTabGroups, terminalEnv]

    /// Echoed through `set-client-info` so the daemon enables additive shapes.
    public static let advertised: [String] = required + optional + [
        "attach-identity-v1",
        "creation-receipts-v1",
        "creation-attempt-keys-v1",
        "terminal-color-overrides-v1",
    ]
}
