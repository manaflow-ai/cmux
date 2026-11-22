import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// R109 review: while tab bars sit at the bottom the window keeps the
/// standard title bar, also when the palette sets `window.titlebar` to
/// minimal (the live value must not skip `effectiveTitlebar`).
@MainActor @Suite(.serialized) struct TitlebarWithBottomTabsTests {
    @Test func minimalFromThePaletteKeepsTheStandardTitlebarWhileTabsAreAtTheBottom() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-titlebar-bottom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs": {"barPosition": "bottom"}}"#.utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url)
        services.settings = settings
        await settings.reload()
        let design = DesignSettings()
        design.tabBarPosition = .bottom
        design.titlebar = .standard
        let context = AppActionContext(services: services, design: design)
        AppearanceHandlers.bind(into: registry, context: context)
        let work = registry.capturingWork { _ = registry.perform("appearance.titlebar.minimal") }
        for task in work { _ = await task.value }
        #expect(design.titlebar == .standard)
    }
}
