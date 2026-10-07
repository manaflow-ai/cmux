import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTerminal
import Testing

extension AppThemeGlobalStateTests {
/// A Ghostty config reload anywhere in the process runs every theme
/// coordinator's re-resolve (`GhosttyRuntime.onConfigChange`). It must not
/// clear a window theme the coordinator did not set: a test's own override
/// came back opaque in Ghostty's default colors when a parallel suite
/// reloaded mid-test (OneBackdropTests on a slow runner).
@MainActor
@Suite(.serialized)
struct ThemeOverrideReloadTests {
    @Test func aWindowsOwnThemeSurvivesAConfigReload() throws {
        _ = NSApplication.shared
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let controller = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        defer { controller.window?.close() }
        var input = ThemeScope.app.input
        input.backgroundOpacity = 0.6
        input.backgroundBlur = 20
        let spec = try #require(ThemeSpec("Catppuccin Mocha"))
        controller.themeScope.setOverride(spec, input: input, animated: false)

        GhosttyRuntime.shared.onConfigChange?()

        #expect(controller.themeScope.spec == spec, "the window keeps the theme it was given")
        #expect(controller.themeScope.tokens.backgroundOpacity == 0.6)
    }
}
}
