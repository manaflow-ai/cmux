import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Onboarding's theme writes to cmux.json (`AppOnboardingServices`) land
/// in order and compare with the file, not with the last loaded snapshot:
/// Skip right after trying a theme puts the user's pick back even before
/// the file watcher has reloaded the try.
@MainActor @Suite struct OnboardingThemeWriteTests {
    @Test func skippingRightAfterTryingAThemePutsThePickBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-onboarding-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"appearance": {"theme": "Catppuccin Mocha"}, "future": {"backgroundOpacity": 0.85}}"#.utf8).write(to: url)

        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        // Not started: no watcher, so the snapshot stays at this first load,
        // as it does in the moment before the watcher reloads a write.
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url)
        services.settings = settings
        await settings.reload()
        let onboarding = AppOnboardingServices(owner: services.onboarding)
        #expect(onboarding.selectedThemeName == "Catppuccin Mocha")

        let density = DesignSettings.shared.density
        onboarding.applyAppearance(themeName: "Nord", density: density)
        onboarding.applyAppearance(themeName: "Catppuccin Mocha", density: density)
        await onboarding.flush()
        let root = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(root.value(at: ["appearance", "theme"]) == "Catppuccin Mocha")
        #expect(root.value(at: ["future", "backgroundOpacity"]) == 0.85)
    }
}
