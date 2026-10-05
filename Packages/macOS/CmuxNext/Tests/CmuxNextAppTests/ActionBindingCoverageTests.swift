import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Testing

/// Binding coverage for the window, workspace (incl. workspace groups),
/// sidebar, settings (incl. appearance), and saved tab group actions, plus
/// the typed-failure contract for features without a capability.
@MainActor
struct ActionBindingCoverageTests {
    static let categories: Set<ActionCategory> = [.window, .workspace, .sidebar, .settings]
    static let savedGroupActions: Set<ActionID> = ["tabGroup.reopenSaved", "tabGroup.deleteSaved"]

    /// Services with every handler bound; no daemon, no windows.
    /// Every catalog action has one owner: the app binds no id twice (diff-host S4 and R89 had both
    /// bound openDiffViewer and palette.openDirectoryDiffViewer).
    @Test func noActionIsBoundTwice() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.registry.assertsOnDuplicateBinding = false
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        #expect(services.registry.duplicateBindings.isEmpty, "\(services.registry.duplicateBindings)")
    }

    static func boundServices() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        return services
    }

    static func run(_ services: AppServices, _ id: String, target: ActionTargetRef? = nil) -> ControlActionOutcome {
        RegistryControlBridge(registry: services.registry).perform(ControlActionRequest(
            actionID: id, target: target.map { ControlTargetRef(kind: $0.kind.rawValue, id: $0.id) }))
    }

    @Test func everyActionInTheseDomainsIsBound() {
        let registry = Self.boundServices().registry
        let unbound = registry.unboundActionIDs(in: Self.categories) + Self.savedGroupActions.filter { !registry.isBound($0) }
        #expect(unbound.isEmpty, "unbound: \(unbound.map(\.rawValue).sorted())")
    }

    @Test func unbuiltFeatureIsUnavailableWithReason() {
        let services = Self.boundServices()
        #expect(Self.run(services, "toggleRightSidebar") == .refused("needs app capability right-sidebar"))
        #expect(!services.registry.canPerform("toggleRightSidebar"))
    }

    @Test func missingDaemonCapabilityIsUnavailableWithReason() {
        let services = Self.boundServices()
        let group = ActionTargetRef(kind: .workspaceGroup, id: "grp_1")
        #expect(Self.run(services, "workspaceGroup.collapse", target: group) == .refused("needs daemon capability profiles-v1"))
        #expect(Self.run(services, "palette.markWorkspaceRead") == .refused("needs daemon capability notification-ack-v1"))
        #expect(Self.run(services, "tabGroup.reopenSaved") == .refused("needs daemon capability tab-groups-v1"))
    }

    @Test func handlerRunsAndReportsBadTargets() {
        let services = Self.boundServices()
        #expect(Self.run(services, "keepMacAwake") == .ran)
        #expect(Self.run(services, "keepMacAwake") == .ran)
        let missing = ActionTargetRef(kind: .workspace, id: "missing")
        #expect(Self.run(services, "palette.copyWorkspaceID", target: missing) == .notFound("no workspace missing"))
    }

    @Test func documentationTopicIsSanitized() {
        #expect(SettingsHandlers.documentationURL(topic: nil).absoluteString == "https://cmux.com/docs")
        #expect(SettingsHandlers.documentationURL(topic: "/workspace-groups").absoluteString == "https://cmux.com/docs/workspace-groups")
        #expect(SettingsHandlers.documentationURL(topic: "../x?y").absoluteString == "https://cmux.com/docs")
    }
}
