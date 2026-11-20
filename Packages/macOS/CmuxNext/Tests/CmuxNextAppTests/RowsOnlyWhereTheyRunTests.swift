import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextDesignTokens
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo, 2026-11-17: "just... stop showijg the toggle on gui." A row that cannot run here is left out
/// (or disabled) instead of being shown and answering with a toast that says to go elsewhere. A
/// keyboard or menu run of one does nothing; only a CLI or MCP run is told why.
@MainActor @Suite(.serialized)
struct RowsOnlyWhereTheyRunTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    /// Debug Settings > Docked workspaces off: every dock action leaves the palette and menus, its
    /// key does nothing (no "turn on Debug Settings first" toast), and the CLI hears why. On, they
    /// are back. Synchronous, so no other suite sees the setting off.
    @Test func dockActionsLeaveWhileDockedWorkspacesIsOff() {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register([LayoutTunables.dockedWorkspaces.descriptor])
        let key = LayoutTunables.dockedWorkspaces.key, before = store.override(key)
        defer { store.set(key, before) }
        let services = Self.services(), registry = services.registry
        store.set(key, .bool(false))
        for id in WindowDockActions.actionIDs {
            #expect(registry.settingOffReason(id) == RefusalStrings.dockedWorkspacesOff, "\(id) stays while docks are off")
            #expect(!registry.isAvailable(id), "\(id) is offered while docks are off")
            #expect(registry.unavailableReason(for: id) == RefusalStrings.dockedWorkspacesOff, "the CLI is not told why \(id) is off")
            let refusal = registry.capturingRefusal { #expect(!registry.perform(id), "\(id) ran while docks are off") }
            #expect(refusal == nil, "\(id) refused (a toast) instead of being left out")
        }
        store.set(key, .bool(true))
        for id in WindowDockActions.actionIDs {
            #expect(registry.settingOffReason(id) == nil, "\(id) is still off with docks on")
        }
    }

    /// The Import from Browser gate and the dock gate both stand: adding one keeps the other.
    @Test func settingOffReasonsAddUp() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        registry.addSettingOffReason(["importFromBrowser"]) { "import off" }
        registry.addSettingOffReason(["workspace.dockLeft"]) { "docks off" }
        #expect(registry.settingOffReason("importFromBrowser") == "import off")
        #expect(registry.settingOffReason("workspace.dockLeft") == "docks off")
        #expect(registry.settingOffReason("newTab") == nil)
    }

    /// View Hang Report is there exactly when this build has hang reports.
    @Test func viewHangReportOnlyWhereHangReportsExist() {
        let registry = Self.services().registry
        let available = AppProcessRoot.shared.hangReports?.isAvailable == true
        #expect((registry.settingOffReason("diagnostics.viewHangReport") == nil) == available)
        #expect(registry.isAvailable("diagnostics.viewHangReport") == available)
    }
}
