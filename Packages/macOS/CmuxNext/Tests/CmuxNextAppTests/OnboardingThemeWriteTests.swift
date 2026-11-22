import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Onboarding's theme and density writes to cmux.json
/// (`AppOnboardingServices`) land in order and compare with the file, not
/// with the last loaded snapshot: Skip right after trying a theme or a
/// density puts the user's choice back even before the file watcher has
/// reloaded the try.
@MainActor @Suite struct OnboardingThemeWriteTests {
    /// Onboarding services over a cmux.json holding `text`, loaded once
    /// and not watched: the snapshot stays at that first load, as it does
    /// in the moment before the watcher reloads a write.
    func onboarding(_ text: String) async throws -> (AppOnboardingServices, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-onboarding-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url)
        services.settings = settings
        await settings.reload()
        return (AppOnboardingServices(owner: services.onboarding), url, directory)
    }

    func document(_ url: URL) throws -> JSONValue { try JSONC.parse(String(contentsOf: url, encoding: .utf8)) }

    @Test func skippingRightAfterTryingAThemePutsThePickBack() async throws {
        let (onboarding, url, directory) = try await onboarding(
            #"{"appearance": {"theme": "Catppuccin Mocha"}, "future": {"backgroundOpacity": 0.85}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(onboarding.selectedThemeName == "Catppuccin Mocha")

        let density = DesignSettings.shared.density
        onboarding.applyAppearance(themeName: "Nord", density: density)
        onboarding.applyAppearance(themeName: "Catppuccin Mocha", density: density)
        await onboarding.flush()
        let root = try document(url)
        #expect(root.value(at: ["appearance", "theme"]) == "Catppuccin Mocha")
        #expect(root.value(at: ["future", "backgroundOpacity"]) == 0.85)
    }

    @Test func skippingRightAfterTryingADensityPutsItBack() async throws {
        let (onboarding, url, directory) = try await onboarding(#"{"appearance": {"theme": "Catppuccin Mocha"}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Try the density the app is not showing now, then go back to the
        // one it shows (the snapshot's view, `DesignSettings.shared`, which
        // other suites also set).
        let original = DesignSettings.shared.density
        let tried: Density = original == .compact ? .comfortable : .compact
        onboarding.applyAppearance(themeName: "Catppuccin Mocha", density: tried)
        onboarding.applyAppearance(themeName: "Catppuccin Mocha", density: original)
        await onboarding.flush()
        let root = try document(url)
        // With no density in the file the app uses compact (`SettingsApplier`).
        let written = root.value(at: ["appearance", "density"])?.stringValue.flatMap(Density.init(rawValue:)) ?? .compact
        #expect(written == original)
        #expect(root.value(at: ["appearance", "theme"]) == "Catppuccin Mocha")
    }
}
