import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextPalette
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// A setting toggled on the palette's Settings page shows its new value on its row at once, keeps
/// it once the write lands, and goes back when the write fails (cx-9ce.20). The row read the
/// loaded settings, the write landed later, and nothing reloaded the page: the row kept its old
/// value until something else reloaded it.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaletteSettingWriteTests {
    struct Harness {
        let settings: SettingsController
        let palette: PaletteController
        let descriptor: SettingDescriptor
        let url: URL

        var rowID: String { "setting:\(descriptor.id)" }
        var row: PaletteItem? { palette.model.rows.first { $0.item.id == rowID }?.item }
        /// The row's on/off state, as its symbol shows it.
        var rowIsOn: Bool? { row.map { $0.symbol == "checkmark.circle.fill" } }
        var storedIsOn: Bool { descriptor.effectiveValue(in: settings.snapshot.root)?.boolValue ?? false }

        func tearDown() {
            // The palette keeps its panel for the next open; this palette has none, so it closes.
            let panel = palette.visiblePanel
            palette.hide()
            panel?.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    func make() async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-palette-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let descriptor = try #require(SettingsSchema.all.first {
            $0.isPaletteExposed && $0.kind == .toggle && $0.defaultValue == .bool(false)
        })
        var sources = PaletteSources()
        sources.settings = SettingsPaletteSource(settings: settings, themeColors: { [] })
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: sources, frecencyPersistence: nil)
        #expect(palette.show(scope: PaletteScopeID.settings))
        palette.model.send(.setQuery(descriptor.title))
        await palette.model.settle()
        return Harness(settings: settings, palette: palette, descriptor: descriptor, url: url)
    }

    /// Runs the row's toggle as Return does.
    func toggle(_ harness: Harness) throws {
        let row = try #require(harness.row, "no row \(harness.rowID) for \(harness.descriptor.title)")
        harness.palette.model.run(row.primary, of: row)
    }

    /// Waits up to 5 s for `done`, for a write that lands off this task (file I/O on another actor).
    /// The row's own value is checked before this runs, so the wait never hides a delay in the row.
    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aToggledSettingShowsItsNewValueAtOnceAndKeepsItWhenTheWriteLands() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        #expect(harness.rowIsOn == false)

        let clock = ContinuousClock()
        let started = clock.now
        try toggle(harness)
        await harness.palette.model.settle()
        let shown = clock.now - started
        #expect(harness.rowIsOn == true, "the row shows the new value without waiting for the write")

        await settle { harness.storedIsOn }
        let landed = clock.now - started
        #expect(harness.storedIsOn, "the write landed")
        await harness.palette.model.settle()
        #expect(harness.rowIsOn == true, "the row keeps the new value once the write lands")
        print("palette setting toggle-to-row: shown \(shown), write landed \(landed)")
        // The palette stays on the same page and query.
        #expect(harness.palette.model.query == harness.descriptor.title)
    }

    @Test func aToggleWhoseWriteFailsGoesBack() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        #expect(harness.rowIsOn == false)
        // The file no longer parses: the write refuses it and fails.
        try Data("{".utf8).write(to: harness.url)

        try toggle(harness)
        await harness.palette.model.settle()
        await settle { harness.rowIsOn == false }
        await harness.palette.model.settle()
        #expect(harness.rowIsOn == false, "a failed write leaves the row on the stored value")
        #expect(!harness.storedIsOn)
    }
}
