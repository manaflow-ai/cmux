import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Palette and action.run must not apply a value for a key an MDM profile or
/// the team policy manages: the file write is refused, so applying the live
/// value first would override the forced value for the session.
@MainActor @Suite(.serialized) struct ManagedSettingActionTests {
    @Test func appearanceActionsRefuseManagedKeysWithoutTouchingTheLiveValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-managed-action-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = ActionRegistry.standard()
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences(forced: ["ui.animationSpeed": "off", "window.titlebar": "standard"])),
                                          managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        AppearanceHandlers.bind(into: registry, context: AppActionContext(services: services))

        let design = DesignSettings.shared
        let speedBefore = design.animationSpeed
        let titlebarBefore = design.titlebar
        defer {
            design.animationSpeed = speedBefore
            design.titlebar = titlebarBefore
        }
        design.animationSpeed = .fast
        design.titlebar = .standard
        // The registry reports that the action ran; the handler refuses before applying anything.
        _ = registry.perform("appearance.animationSpeed.normal")
        #expect(design.animationSpeed == .fast)
        _ = registry.perform("appearance.titlebar.minimal")
        #expect(design.titlebar == .standard)
    }
}
