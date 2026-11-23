import AppKit
@testable import CmuxNextActions
@testable import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// Copy Cloud Session Link (#40159) is a row of the workspace and tab Copy folders. On a local
/// workspace or tab it can only refuse (`cloud_session.not_cloud`), so that menu leaves it out, as
/// macOS menus leave out what does not apply. The palette and the CLI keep it.
@MainActor @Suite struct CloudTeamMenuRowsTests {
    /// A signed-in team member with no Cloud machine: every workspace and tab is local.
    @MainActor final class LocalOnlyHost: CloudTeamHost {
        func cloudTeamCall(_ path: String, _ body: [String: Any], team: String?) async throws -> [String: Any] { [:] }
        var cloudTeamSignedIn: Bool { true }
        var cloudTeamID: String? { "team-1" }
        var cloudTeamUserID: String? { "user-1" }
        var cloudTeamMachineIDs: [String] { [] }
        func cloudTeamStore(_ vm: String) -> DaemonStore? { nil }
        func cloudTeamStatus(_ vm: String) -> String? { nil }
        var cloudTeamActiveMachine: String? { nil }
        var cloudTeamActiveWorkspaceKey: String? { nil }
        func cloudTeamWorkspace(_ id: String) -> WorkspaceModel? { nil }
        func cloudTeamWorkspaceMachine(_ id: String) -> String? { nil }
        func cloudTeamRevealTab(_ id: String, intent: WindowActivation.Intent) -> Bool { false }
        func cloudTeamWindow(workspace key: String) -> NSWindow? { nil }
        func cloudTeamShowWindow(_ window: NSWindow, intent: WindowActivation.Intent) {}
        var cloudTeamTokens: ThemeTokens { ThemeScope.app.tokens }
    }

    /// Every action a menu runs, submenus included.
    private func allActions(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item in
            (ActionRegistry.menuRun(of: item).map { [$0.id.rawValue] } ?? []) + (item.submenu.map(allActions) ?? [])
        }
    }

    @Test(arguments: [(ActionMenuContext.workspaceRow, ActionTargetKind.workspace), (.tab, .tab)]
          as [(ActionMenuContext, ActionTargetKind)])
    func aLocalTargetsMenuHasNoCloudSessionLink(context: ActionMenuContext, kind: ActionTargetKind) {
        let host = LocalOnlyHost()
        let feature = CloudTeamFeature(host: host)
        let registry = ActionRegistry.standard()
        feature.bind(into: registry, reason: { nil })
        let menu = registry.makeContextMenu(for: context, target: ActionTargetRef(kind: kind, id: "local"))
        #expect(!allActions(menu).contains("cloud.team.copyLink"), "\(context): \(allActions(menu))")
        // Still offered elsewhere: a run on a local target refuses with cloud_session.not_cloud.
        #expect(registry.isAvailable("cloud.team.copyLink"))
        withExtendedLifetime((host, feature)) {}
    }
}
