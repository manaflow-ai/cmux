import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// An action gated on a daemon capability asks the daemon it will command
/// when availability is asked (the routed or active window's machine), not
/// the daemon that was active when the action was bound at launch. A Cloud
/// machine on an older cmux-tui must show the action unavailable even
/// while the local daemon has the capability.
@MainActor @Suite struct CallTimeCapabilityGateTests {
    nonisolated static let gated: [ActionID] = [
        "palette.toggleTabUnread",
        "tabGroup.create",
        "markAllNotificationsRead",
        "markOldestUnreadAndJumpNext",
        "toggleUnread",
        "notificationToggleRead",
        "notificationDismiss",
        "notificationCopy",
        "clearAllNotifications",
    ]

    @Test(arguments: gated) func theGateReadsTheMachineTheActionCommands(_ id: ActionID) {
        let services = ActionBindingCoverageTests.boundServices()
        let everything = DaemonCapabilities.shared.required + DaemonCapabilities.shared.optional
        services.daemon.store.noteHandshake(DaemonIdentity(capabilities: everything, generation: "g1"))
        #expect(services.registry.unavailableReason(for: id) == nil, "the local daemon serves \(id)")

        let cloud = DaemonService(machineID: "vm")
        cloud.store.noteHandshake(DaemonIdentity(capabilities: CloudVMDaemonCapabilities.list, generation: "g1"))
        services.routedDaemon = cloud
        defer { services.routedDaemon = nil }
        #expect(services.registry.unavailableReason(for: id) != nil, "\(id) on the Cloud VM daemon")
    }
}

/// `advertised_capabilities` of cmux-tui 7d177547949b, a Cloud VM image's daemon.
enum CloudVMDaemonCapabilities {
    static let list: [String] = [
        "attach-initial-size", "attach-identity-v1", "workspace-registry-v1", "daemon-handoff-force-v1",
        "browser-pointer-frame-guard-v1", "viewport-splits-v1", "viewport-column-resize-v1", "layout-undo-v1",
        "tab-workspace-move-v1", "clear-history-v1", "surface-subscribe-filter", "session-journal-v1",
        "frontend-journal-v1", "view-attachment-lease-v1", "view-attachment-detach-v1", "shared-sizing-v1",
        "terminal-color-overrides-v1", "terminal-pending-sequence-v1", "creation-receipts-v1",
        "creation-attempt-keys-v1", "creation-selector-fallbacks-v1",
        "provider-managed-workspace-authority-v2", "browser-provider-v1", "client-focus-v1",
        "machine-usage-v1", "machine-listening-tcp-v1", "server-stats-v1", "terminal-idle-close-v1",
    ]
}
