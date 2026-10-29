#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextOracle
import CmuxNextSettings
import Foundation
import Testing

/// The app's settings facet reads the snapshot the settings controller applied: a preview shows
/// in it, and a file edit the controller has not loaded does not (the snapshot's turn opens no file). Its motion
/// arm is what the gates compute from the design settings the controller applied, not the config's own values.
/// Run: `swift test --filter AppOracleSettingsFacetTests`.
@MainActor @Suite(.serialized) struct AppOracleSettingsFacetTests {
    /// App services whose settings controller has loaded `text` from `cmux-next.json` in `directory`.
    private func loadedServices(_ text: String, in directory: URL) async throws -> (AppServices, SettingsController, URL) {
        _ = NSApplication.shared
        let url = directory.appending(path: "cmux-next.json")
        try Data(text.utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return (services, settings, url)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-oracle-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func facet(_ services: AppServices) throws -> OracleValue? {
        try #require(try services.makeOracleFacets().beginCapture([.settings]).completed)["settings"]
    }

    @Test func withoutASettingsControllerTheFacetIsNotComparable() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.settings = nil
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.settings))
        let snapshot = try #require(try facets.beginCapture([.settings]).completed)
        #expect(snapshot["settings"]?["status"] == "not-comparable")
        #expect(snapshot["settings"]?["task"] == "p15-oracle-039")
    }

    @Test func theFacetReadsTheAppliedSnapshotNotTheFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (services, settings, url) = try await loadedServices(#"{"ui":{"animations":{"enabled":false}}}"#, in: directory)

        let loaded = try facet(services)
        #expect(loaded?["effectiveSha256"] == .string(settings.applied.effectiveSha256))
        #expect(loaded?["nonDefaultKeys"] == ["ui.animations.enabled"])
        #expect(loaded?["motion"]?["enabled"] == false)
        #expect(loaded?["motion"]?["speed"] == 1)
        #expect(loaded?["motion"]?["reduceMotion"] == .bool(Motion.reduceMotion(of: settings.design)))

        // Not loaded yet: the facet still answers what the controller applied.
        try Data(#"{"ui":{"animationSpeed":"off"}}"#.utf8).write(to: url)
        #expect(try facet(services) == loaded)

        let speed = try #require(SettingsSchema.descriptor(for: AnimationSpeedSetting.configPath))
        #expect(settings.preview(speed, "normal"))
        let previewed = try facet(services)
        #expect(previewed?["motion"]?["speed"] == 1.5)
        #expect(previewed?["nonDefaultKeys"] == ["ui.animationSpeed", "ui.animations.enabled"])
        settings.endPreview()
        #expect(try facet(services) == loaded)
    }

    /// `ui.calm` "still" leaves `ui.animations.enabled` at its default (on) but turns every gate off, so the arm
    /// reads back off.
    @Test func calmStillReadsBackTheGatesOff() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (services, settings, _) = try await loadedServices(#"{"ui":{"calm":"still"}}"#, in: directory)
        #expect(settings.applied.motionCategories.enabled)
        #expect(!Motion.basePolicy(of: settings.design).animationsEnabled)

        let reading = try facet(services)
        #expect(reading?["motion"]?["enabled"] == false)
        #expect(reading?["motion"]?["reduceMotion"] == .bool(Motion.reduceMotion(of: settings.design)))
        #expect(reading?["nonDefaultKeys"] == ["ui.calm"])
    }
}
#endif
