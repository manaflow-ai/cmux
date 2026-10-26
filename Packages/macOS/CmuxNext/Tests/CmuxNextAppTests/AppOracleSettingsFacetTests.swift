#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextOracle
import CmuxNextSettings
import Foundation
import Testing

/// The app's settings facet (p15-oracle-039) reads the snapshot the settings controller applied: a preview shows
/// in it, and a file edit the controller has not loaded does not (the snapshot's turn opens no file).
/// Run: `swift test --filter AppOracleSettingsFacetTests`.
@MainActor @Suite(.serialized) struct AppOracleSettingsFacetTests {
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
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-oracle-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux-next.json")
        try Data(#"{"ui":{"animations":{"enabled":false}}}"#.utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()

        func facet() throws -> OracleValue? {
            try #require(try services.makeOracleFacets().beginCapture([.settings]).completed)["settings"]
        }
        let loaded = try facet()
        #expect(loaded?["effectiveSha256"] == .string(settings.applied.effectiveSha256))
        #expect(loaded?["nonDefaultKeys"] == ["ui.animations.enabled"])
        #expect(loaded?["motion"]?["enabled"] == false)
        #expect(loaded?["motion"]?["speed"] == 1)
        #expect(loaded?["motion"]?["reduceMotion"] == .bool(Motion.reduceMotion))

        // Not loaded yet: the facet still answers what the controller applied.
        try Data(#"{"ui":{"animationSpeed":"off"}}"#.utf8).write(to: url)
        #expect(try facet() == loaded)

        let speed = try #require(SettingsSchema.descriptor(for: AnimationSpeedSetting.configPath))
        #expect(settings.preview(speed, "normal"))
        let previewed = try facet()
        #expect(previewed?["motion"]?["speed"] == 1.5)
        #expect(previewed?["nonDefaultKeys"] == ["ui.animationSpeed", "ui.animations.enabled"])
        settings.endPreview()
        #expect(try facet() == loaded)
    }
}
#endif
