import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `layout.panePadding`, `layout.paneCornerRadius` and `layout.paneBorder`.
@Suite struct PaneChromeSnapshotTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func parsesEveryKey() throws {
        let snapshot = try parse(#"{"layout": {"panePadding": 3, "paneCornerRadius": 0, "paneBorder": "none"}}"#)
        #expect(snapshot.paneChrome == PaneChromeOverrides(padding: 3, cornerRadius: 0, border: PaneBorderStyle.none))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func missingKeysFollowTheDefaults() throws {
        #expect(try parse(#"{}"#).paneChrome == PaneChromeOverrides())
        #expect(try parse(#"{"layout": {"paneBorder": "subtle"}}"#).paneChrome == PaneChromeOverrides(border: .subtle))
    }

    @Test func badValuesAreSkippedWithDiagnostics() throws {
        let snapshot = try parse(#"{"layout": {"panePadding": "wide", "paneBorder": "thick", "paneCornerRadius": 99}}"#)
        #expect(snapshot.paneChrome.padding == nil)
        #expect(snapshot.paneChrome.border == nil)
        #expect(snapshot.paneChrome.cornerRadius == 20)  // clamped
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["layout.panePadding", "layout.paneBorder", "layout.paneCornerRadius"])
        #expect(snapshot.diagnostics.allSatisfy { $0.kind == .invalidValue })
        let notObject = try parse(#"{"layout": 4}"#)
        #expect(notObject.diagnostics.map(\.path) == ["layout"])
    }
}

@MainActor
@Suite struct PaneChromeApplierTests {
    @Test func appliesAndRevertsWhenKeysLeaveTheFile() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        let root = try JSONC.parse(#"{"layout": {"panePadding": 0, "paneBorder": "none"}}"#)
        applier.apply(CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))
        #expect(design.paneChrome == PaneChromeOverrides(padding: 0, border: PaneBorderStyle.none))

        applier.apply(CmuxConfigSnapshot.parse(.object([:]), validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))
        #expect(design.paneChrome == PaneChromeOverrides())
    }
}

extension SettingsControllerTests {
    @Test func paneChromeWritesApplyLiveThroughTheWatcher() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}\n".utf8).write(to: url)
        let design = DesignSettings()
        let controller = SettingsController(registry: ActionRegistry.standard(), design: design, fileURL: url)
        controller.start()
        defer { controller.stop() }
        try await nextLoad(controller, after: 0)

        try await controller.setPanePadding(0)
        try await controller.setPaneBorder(PaneBorderStyle.none)
        try await controller.setPaneCornerRadius(4)
        try await eventually(controller) { design.paneChrome == PaneChromeOverrides(padding: 0, cornerRadius: 4, border: PaneBorderStyle.none) }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"panePadding\": 0"))
        #expect(text.contains("\"paneBorder\": \"none\""))

        // Removing the keys restores the defaults.
        try await controller.setPanePadding(nil)
        try await controller.setPaneBorder(nil)
        try await controller.setPaneCornerRadius(nil)
        try await eventually(controller) { design.paneChrome == PaneChromeOverrides() }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("layout") == false)
    }
}

@Suite struct ConfigFileLocationTests {
    @Test func overrideReplacesTheHomeFile() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(CmuxConfigFile.defaultURL(home: home, environment: [:]).path == "/Users/someone/.config/cmux/cmux-next.json")
        #expect(CmuxConfigFile.defaultURL(home: home, environment: [CmuxConfigFile.overrideKey: ""]).path == "/Users/someone/.config/cmux/cmux-next.json")
        #expect(CmuxConfigFile.defaultURL(home: home, environment: [CmuxConfigFile.overrideKey: "/tmp/t/cmux.json"]).path == "/tmp/t/cmux.json")
    }

    @Test func firstLaunchCopiesClassicConfigOnce() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cmux-next-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let classic = home.appending(path: ".config/cmux/cmux.json")
        try FileManager.default.createDirectory(at: classic.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"shortcuts\": {\"newTab\": \"cmd+t\"}}\n".utf8).write(to: classic)

        let next = try CmuxConfigFile.prepareDefaultURL(home: home, environment: [:])
        #expect(next.lastPathComponent == "cmux-next.json")
        #expect(try String(contentsOf: next, encoding: .utf8) == "{\"shortcuts\": {\"newTab\": \"cmd+t\"}}\n")

        try Data("{\"shortcuts\": {\"newTab\": \"cmd+w\"}}\n".utf8).write(to: classic)
        _ = try CmuxConfigFile.prepareDefaultURL(home: home, environment: [:])
        #expect(try String(contentsOf: next, encoding: .utf8) == "{\"shortcuts\": {\"newTab\": \"cmd+t\"}}\n")
    }

    @Test func firstLaunchWithoutClassicCreatesOwnConfig() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cmux-next-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let next = try CmuxConfigFile.prepareDefaultURL(home: home, environment: [:])
        #expect(try String(contentsOf: next, encoding: .utf8) == "{}\n")
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".config/cmux/cmux.json").path))
    }

    @Test func explicitOverrideDoesNotReadClassicConfig() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cmux-next-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let classic = home.appending(path: ".config/cmux/cmux.json")
        try FileManager.default.createDirectory(at: classic.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"classic\": true}\n".utf8).write(to: classic)
        let override = home.appending(path: "scratch.json")

        let result = try CmuxConfigFile.prepareDefaultURL(
            home: home,
            environment: [CmuxConfigFile.overrideKey: override.path]
        )
        #expect(result == override)
        #expect(!FileManager.default.fileExists(atPath: override.path))
    }
}
