import CMUXMobileCore
import Foundation

extension MobileHostService {
    /// Advertises the Mac-side support required before iOS may configure
    /// authenticated Iroh private-path candidates.
    nonisolated static let irohPrivatePathsCapability = "iroh.private_paths.v1"
#if DEBUG
    /// Complete method inventory returned only to the authenticated Iroh release
    /// gate. The phone compares this independently maintained host inventory with
    /// its own required-method inventory before exercising representative RPCs.
    nonisolated static let irohReleaseGateRPCMethods: [String] = [
        "dogfood.feedback.submit",
        "mobile.attach_ticket.create",
        "mobile.browser.back",
        "mobile.browser.create",
        "mobile.browser.dialog.respond",
        "mobile.browser.forward",
        "mobile.browser.frame.ack",
        "mobile.browser.input.key",
        "mobile.browser.input.pointer",
        "mobile.browser.input.scroll",
        "mobile.browser.input.text",
        "mobile.browser.list",
        "mobile.browser.navigate",
        "mobile.browser.reload",
        "mobile.browser.stream.start",
        "mobile.browser.stream.stop",
        "mobile.browser.viewport",
        "mobile.chat.answer",
        "mobile.chat.artifact.fetch",
        "mobile.chat.artifact.gallery",
        "mobile.chat.artifact.list",
        "mobile.chat.artifact.stat",
        "mobile.chat.artifact.thumbnail",
        "mobile.chat.history",
        "mobile.chat.interrupt",
        "mobile.chat.send",
        "mobile.chat.session",
        "mobile.chat.sessions",
        "mobile.directory.list",
        "mobile.directory.search",
        "mobile.events.probe",
        "mobile.events.subscribe",
        "mobile.events.unsubscribe",
        "mobile.host.status",
        "mobile.rpc.methods",
        "mobile.simulator.input.button",
        "mobile.simulator.input.pointer",
        "mobile.simulator.input.text",
        "mobile.simulator.list",
        "mobile.simulator.stream.start",
        "mobile.simulator.stream.stop",
        "mobile.sync.fetch",
        "mobile.task.attachment.upload",
        "mobile.task.models.list",
        "mobile.terminal.artifact.fetch",
        "mobile.terminal.artifact.list",
        "mobile.terminal.artifact.scan",
        "mobile.terminal.artifact.stat",
        "mobile.terminal.artifact.thumbnail",
        "mobile.terminal.create",
        "mobile.terminal.input",
        "mobile.terminal.mouse",
        "mobile.terminal.paste",
        "mobile.terminal.paste_image",
        "mobile.terminal.replay",
        "mobile.terminal.scroll",
        "mobile.terminal.viewport",
        "mobile.workspace.changes.file_diff",
        "mobile.workspace.changes.file_fetch",
        "mobile.workspace.changes.file_stat",
        "mobile.workspace.changes.files",
        "mobile.workspace.changes.summary",
        "mobile.workspace.list",
        "notification.dismiss",
        "notification.feed.list",
        "notification.feed.mark_all_read",
        "notification.feed.mark_read",
        "notification.feed.mark_unread",
        "notification.reconcile",
        "phone_push.settings.update",
        "phone_push.status.get",
        "phone_push.test",
        "terminal.create",
        "terminal.input",
        "terminal.mouse",
        "terminal.paste",
        "terminal.paste_image",
        "terminal.replay",
        "terminal.scroll",
        "terminal.viewport",
        "workspace.action",
        "workspace.close",
        "workspace.create",
        "workspace.group.action",
        "workspace.group.collapse",
        "workspace.group.create",
        "workspace.group.expand",
        "workspace.list",
        "workspace.move",
    ]
#endif
    nonisolated static let irohArtifactLaneCapability = "iroh.artifact_lane.v1"
    nonisolated static let terminalInputOrderedCapability = "terminal.input.ordered.v1"
    nonisolated static let workspaceChangesCapability = "workspace.changes.v1"
    /// Authenticated status includes the Mac's independent phone-forwarding
    /// gate, presence mode, account proof, and API endpoint identity.
    nonisolated static let phonePushStatusCapability = "phone_push.status.v1"
    nonisolated static let phonePushSettingsCapability = "phone_push.settings.v1"
    /// Authenticated request to enqueue a truthful, correlated test alert.
    nonisolated static let phonePushTestCapability = "phone_push.test.v1"
    /// Read and mutate cmux's process-scoped idle-sleep assertion.
    nonisolated static let caffeineControlCapability = "caffeine.control.v1"
    nonisolated static let taskCreateCapability = "workspace.task_create.v1"
    nonisolated static let taskAttachmentCapability = "task.attachments.v1"
    nonisolated static let taskModelsCapability = "task.models.v1"
    nonisolated static let taskDirectoryBrowseCapability = "workspace.directory_browse.v1"
    nonisolated static let taskDirectorySearchCapability = "workspace.directory_search.v1"
    nonisolated static let taskDirectorySearchV2Capability = "workspace.directory_search.v2"

    /// The single source of truth for the capabilities advertised to mobile
    /// clients via `mobile.host.status`. Every status path (the public-status
    /// cache, the network status gate, and `TerminalController`'s
    /// full status) reads this so the lists cannot drift; iOS gates features
    /// like rename/pin/read-state/close/move/group actions on the entries
    /// present here.
    ///
    /// This also advertises `dogfood.v1`, the agent feedback round-trip
    /// (`dogfood.feedback.submit`). It is advertised on every build type so the
    /// privileged Send Feedback path (offered only to `@manaflow.ai` users on an
    /// active connection) works on Release (beta/prod) too; the sink itself is
    /// still gated by the same-account Stack-auth check the rest of the mobile
    /// data plane enforces.
    nonisolated static var mobileHostCapabilities: [String] {
        mobileHostCapabilities(
            includingWorkspaceChanges: CmuxFeatureFlags.offMainEffectiveValue(
                for: CmuxFeatureFlags.mobileWorkspaceChangesFlag
            ),
            includingSimulator: CmuxFeatureFlags.offMainEffectiveValue(
                for: CmuxFeatureFlags.simulatorFlag
            ),
            includingTaskComposer: CmuxFeatureFlags.offMainEffectiveValue(
                for: CmuxFeatureFlags.mobileTaskComposerFlag
            ),
            // Managed policy only: under it every browser pane is closed, so
            // no browser affordance can work. A user-level disable keeps live
            // panes (session restore re-materializes them), and iOS must
            // still be able to view/stream those, so keep advertising then.
            includingBrowser: !BrowserAvailabilitySettings.isManagedByPolicy
        )
    }

    /// The mobile diff viewer ships behind a remote feature flag: when the
    /// flag is off this list omits `workspace.changes.v1`, and every iOS
    /// entry point (chip, toolbar button, hint, sheet, summary polling)
    /// feature-detects itself away. The RPC dispatch applies the same flag,
    /// so a phone holding a stale capability list cannot call through.
    /// `includingSimulator` mirrors the same pattern for the simulator
    /// capabilities: `mobile.simulator.list`, stream start, and simulator
    /// input all refuse with `capability_disabled` when
    /// `simulator-enabled-release` is off, so advertising the capabilities
    /// unconditionally would make iOS show Simulator rows whose first stream
    /// or input call then fails.
    nonisolated static func mobileHostCapabilities(
        includingWorkspaceChanges: Bool,
        includingSimulator: Bool = true,
        includingTaskComposer: Bool = true,
        includingBrowser: Bool = true
    ) -> [String] {
        var capabilities = [
            Self.irohPrivatePathsCapability,
            MobileBrowserStreamCapability.identifier,
            MobileBrowserStreamCapability.viewportIdentifier,
            MobileBrowserStreamCapability.dialogIdentifier,
            MobileBrowserStreamCapability.createIdentifier,
            MobileSimulatorStreamCapability.current.identifier,
            MobileSimulatorStreamCapability.current.inputIdentifier,
            MobileSimulatorStreamCapability.current.ownershipIdentifier,
            MobileSimulatorStreamCapability.current.keepaliveIdentifier,
            "events.v1",
            "notification.badge.v1",
            "notification.dismiss.v1",
            "notification.feed.v1",
            "notification.reconcile.v1",
            "terminal.bytes.v1",
            "terminal.render_grid.v1",
            "terminal.render_grid.verified_replay.v1",
            // Screen-anchored render grids: frames anchor to the active area
            // (independent of the Mac's scroll position), deltas carry exact
            // scrolled-row counts, and replays honor max_scrollback_rows, so
            // the phone owns a deep local scrollback and scrolls it locally.
            "terminal.render_grid.screen_anchor.v1",
            "terminal.replay.v1",
            Self.terminalInputOrderedCapability,
            "terminal.viewport.v1",
            "terminal.artifact.v1",
            "terminal.artifact.list.v1",
            "panel.artifact.v1",
            "workspace.actions.v1",
            "workspace.surfaces.v1",
            "surface.focus.v1",
            "todo.v1",
            Self.workspaceChangesCapability,
            "workspace.metadata.v1",
            "workspace.read_state.v1",
            "workspace.close.v1",
            "workspace.move.v1",
            "workspace.group_actions.v1",
            "workspace.group_create.v1",
            "workspace.create_in_group.v1",
            // Mac-scoped workspace mutations (move, group actions/create,
            // create-in-group) are authorized by the signed-in Stack account;
            // an attach ticket only narrows scope while current. iOS keeps the
            // drag-and-drop and group-create affordances enabled after ticket
            // expiry only against hosts that advertise this.
            "workspace.mutations.account_auth.v1",
            Self.taskCreateCapability,
            Self.taskAttachmentCapability,
            Self.taskModelsCapability,
            Self.taskDirectoryBrowseCapability,
            Self.taskDirectorySearchCapability,
            Self.taskDirectorySearchV2Capability,
            Self.caffeineControlCapability,
            "chat.artifact.v1",
            "chat.artifact.folders.v1",
            "chat.artifact.gallery.v1",
            "dogfood.v1",
            // The workspace list carries group sections (group_id per workspace +
            // a top-level groups array) and the host accepts
            // workspace.group.collapse/expand from mobile. iOS feature-detects
            // this to render collapsible groups only against a Mac that emits them.
            "workspace.groups.v1",
        ]
        if !includingWorkspaceChanges {
            capabilities.removeAll { $0 == Self.workspaceChangesCapability }
        }
        if !includingSimulator {
            let simulatorCapabilities: Set<String> = [
                MobileSimulatorStreamCapability.current.identifier,
                MobileSimulatorStreamCapability.current.inputIdentifier,
                MobileSimulatorStreamCapability.current.ownershipIdentifier,
                MobileSimulatorStreamCapability.current.keepaliveIdentifier,
            ]
            capabilities.removeAll { simulatorCapabilities.contains($0) }
        }
        if !includingTaskComposer {
            let taskComposerCapabilities: Set<String> = [
                Self.taskCreateCapability,
                Self.taskAttachmentCapability,
                Self.taskModelsCapability,
                Self.taskDirectoryBrowseCapability,
                Self.taskDirectorySearchCapability,
                Self.taskDirectorySearchV2Capability,
            ]
            capabilities.removeAll { taskComposerCapabilities.contains($0) }
        }
        if !includingBrowser {
            // The embedded browser is disabled by MDM policy: every pane is
            // closed and none can be created, so stop advertising browser
            // streaming/creation and iOS feature-detects the affordances away.
            let browserCapabilities: Set<String> = [
                MobileBrowserStreamCapability.identifier,
                MobileBrowserStreamCapability.viewportIdentifier,
                MobileBrowserStreamCapability.dialogIdentifier,
                MobileBrowserStreamCapability.createIdentifier,
            ]
            capabilities.removeAll { browserCapabilities.contains($0) }
        }
        return applyingDebugCapabilitySuppressions(capabilities)
    }

    nonisolated static func applyingDebugCapabilitySuppressions(
        _ capabilities: [String]
    ) -> [String] {
        #if DEBUG
        // Lets a dev Mac impersonate an older host while dogfooding the iOS update hint.
        let suppressed = Set(
            (ProcessInfo.processInfo.environment["CMUX_DEBUG_SUPPRESS_MOBILE_CAPS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return capabilities.filter { !suppressed.contains($0) }
        #else
        return capabilities
        #endif
    }
}
