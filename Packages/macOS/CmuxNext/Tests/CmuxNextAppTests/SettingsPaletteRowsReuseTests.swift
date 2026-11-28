import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import CmuxNextSettingsWindow
import Foundation
import Testing

/// Every Cmd-Shift-P built the row of every palette setting again, each with its whole value list
/// (formatted numbers and durations, theme and font lists), right after the palette's first frame:
/// about 8 ms of the main thread per open in a fleet sample (40 opens, cmux11s), on the frames the
/// palette's open animation draws. With no setting changed, an open lists the rows the last one built.
@MainActor @Suite(.serialized) struct SettingsPaletteRowsReuseTests {
    struct Harness {
        let settings: SettingsController
        let source: SettingsPaletteSource
        let directory: URL

        func tearDown() {
            settings.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func make(colors: @escaping @MainActor () -> [ThemeRGB] = { [] }) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-palette-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return Harness(settings: settings, source: SettingsPaletteSource(settings: settings, themeColors: colors), directory: directory)
    }

    @Test func opensWithNoChangeListTheRowsAlreadyBuilt() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        let first = harness.source.rows
        #expect(!first.isEmpty)
        #expect(harness.source.rowBuilds == 1)
        for _ in 0..<5 { _ = harness.source.rows }
        #expect(harness.source.rowBuilds == 1, "an open with no setting changed built every row again")
        #expect(harness.source.rows.map(\.id) == first.map(\.id))
    }

    /// A load that changed nothing (the app's activation asks for one, to read managed preferences)
    /// keeps the rows: the first Cmd-Shift-P after switching back to cmux built every row again.
    @Test func aLoadThatChangedNothingKeepsTheRows() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = harness.source.rows
        let loads = harness.settings.loadCount
        harness.settings.managedPreferencesMayHaveChanged()
        await harness.settings.waitForLoad(atLeast: loads + 1)
        #expect(harness.settings.loadCount > loads)
        _ = harness.source.rows
        #expect(harness.source.rowBuilds == 1, "a load with nothing changed built every row again")
    }

    /// A loaded change (the file edited, a write landed) builds the rows again, and they show it.
    @Test func aLoadedChangeBuildsTheRowsAgain() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        let descriptor = try #require(SettingsSchema.all.first {
            $0.isPaletteListed(developerTools: DevTools.isEnabled) && $0.kind == .toggle && $0.defaultValue == .bool(false)
        })
        let before = try #require(harness.source.rows.first { $0.id == descriptor.id })
        guard case .toggle(let wasOn) = before.kind else { Issue.record("not a toggle row"); return }
        #expect(!wasOn)
        try await harness.settings.setSetting(descriptor, to: .bool(true), by: .user)
        await harness.settings.reload()
        let after = try #require(harness.source.rows.first { $0.id == descriptor.id })
        guard case .toggle(let isOn) = after.kind else { Issue.record("not a toggle row"); return }
        #expect(isOn, "the row kept the value from before the load")
        #expect(harness.source.rowBuilds == 2)
    }

    /// The window's theme colors (a color setting's swatches) are an input too.
    @Test func otherThemeColorsBuildTheRowsAgain() async throws {
        var colors: [ThemeRGB] = []
        let harness = try await make(colors: { colors })
        defer { harness.tearDown() }
        _ = harness.source.rows
        colors = [ThemeRGB(r: 1, g: 2, b: 3)]
        _ = harness.source.rows
        #expect(harness.source.rowBuilds == 2)
        _ = harness.source.rows
        #expect(harness.source.rowBuilds == 2)
    }
}
