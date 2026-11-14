import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextSettings
import CmuxNextSettingsWindow
import Testing

@MainActor
struct SidebarCustomizationEntryPointTests {
    @Test func backgroundMenuAndActionOpenTheSameSidebarPage() throws {
        let registry = ActionRegistry.standard()
        var opens: [(String, Bool)] = []
        SettingsCustomizationActions().bind(into: registry) { opens.append(($0, $1)); return .done }
        let menu = registry.makeContextMenu(for: .sidebarBackground)
        let item = try #require(menu.items.first { ActionRegistry.menuRun(of: $0)?.id == "sidebar.customize" })
        #expect(item.isEnabled)
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(opens.count == 1)
        #expect(registry.perform("sidebar.customize", invocation: ActionInvocation(origin: .user)))
        #expect(opens.count == 2)
        #expect(opens.allSatisfy { $0.0.hasPrefix("#/settings/sidebar?open=") && $0.1 })
        if opens.count == 2 { #expect(opens[0].0 != opens[1].0) }
    }

    @Test func automationDoesNotStealFocus() {
        let registry = ActionRegistry.standard()
        var focus: Bool?
        SettingsCustomizationActions().bind(into: registry) { _, requested in focus = requested; return .done }
        #expect(registry.perform("sidebar.customize", invocation: ActionInvocation(origin: .cli)))
        #expect(focus == false)
    }

    @Test func repeatOpensUseDistinctRoutes() {
        #expect(SettingsDeepLink.sidebarRoute(open: 1) == "#/settings/sidebar?open=1")
        #expect(SettingsDeepLink.sidebarRoute(open: 1) != SettingsDeepLink.sidebarRoute(open: 2))
    }

    @Test func sidebarPageKeepsTheAdvancedConfigPath() throws {
        let sidebar = try #require(SettingsPageLayout().categories().first { $0.spec.id == "sidebar" })
        #expect(sidebar.spec.actions.contains(.rooms))
        #expect(SettingsSchema.actions(in: .rooms).contains("palette.openCmuxSettingsFile"))
    }
}
