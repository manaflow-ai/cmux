import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextTerminal
import Foundation
import Testing

/// `ui.reducedBackgrounds`: on, every window draws the plain theme background (no painting, no
/// workspace or pane picture, no glass), applied where the app applies `appearance.*`
/// (`TerminalThemeSetting` on the scope windows inherit from). Off restores exactly what the
/// person chose, because their `appearance.*` values never change.
@MainActor @Suite(.serialized) struct ReducedBackgroundsTests {
    static let work = "van-gogh-starry-night"
    static let pinned = BackdropSelection.art(.munchScream)

    struct Harness {
        let settings: SettingsController
        let terminal: TerminalThemeSetting
        let room: ThemeScope
        let workspace: ThemeScope
        let url: URL
        var file: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    /// The person's background: a painting, a workspace with its own picture, and the Glass material.
    func make(reduced: Bool?) async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-reduced-backgrounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        let ui = reduced.map { #", "ui": {"reducedBackgrounds": \#($0)}"# } ?? ""
        let json = #"{"appearance": {"background": "\#(Self.work)", "backgroundBlur": "glass"}\#(ui)}"#
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.pinBackdrop(.selection(Self.pinned))
        let terminal = TerminalThemeSetting(backdropScope: room)
        terminal.reload = {}
        terminal.repaint = {}
        terminal.follow(settings)
        return Harness(settings: settings, terminal: terminal, room: room, workspace: workspace, url: url)
    }

    func tearDown(_ harness: Harness) {
        GhosttyRuntime.backgroundOverride = WindowBackgroundOverride()
        GhosttyConfigBackground.loaded = GhosttyConfigBackground()
        try? FileManager.default.removeItem(at: harness.url.deletingLastPathComponent())
    }

    /// Waits for the observers (`ObservationStream`) to see a change.
    func settle(until done: () -> Bool) async {
        for _ in 0..<400 where !done() { await Task.yield() }
    }

    /// Unset (today's behavior): the painting, the workspace's picture and the glass all draw.
    @Test func offByDefaultDrawsThePersonsBackground() async throws {
        let harness = try await make(reduced: nil)
        defer { tearDown(harness) }
        #expect(harness.settings.snapshot.reducedBackgrounds == false)
        #expect(harness.room.backdropSelection?.id == Self.work)
        #expect(harness.workspace.backdropSelection == Self.pinned)
        #expect(GhosttyRuntime.backgroundOverride.material == .glass)
    }

    /// On: no picture anywhere and an opaque, unblurred window. Off again: everything is back,
    /// and cmux.json still holds the person's `appearance.*` values.
    @Test func onDrawsThePlainThemeBackgroundAndOffRestoresIt() async throws {
        let harness = try await make(reduced: true)
        defer { tearDown(harness) }
        #expect(harness.settings.snapshot.reducedBackgrounds)
        #expect(harness.room.backdropSelection == nil, "the painting still draws")
        #expect(harness.workspace.backdropSelection == nil, "the workspace's own picture still draws")
        #expect(GhosttyRuntime.backgroundOverride == ReducedBackgroundsSetting.plainWindowBackground,
                "the window keeps \(GhosttyRuntime.backgroundOverride)")
        let resolved = GhosttyRuntime.backgroundOverride.resolved(backgroundOpacity: 0.7, backgroundBlur: -1)
        #expect(resolved.backgroundOpacity == 1 && resolved.backgroundBlur == 0)

        try await harness.settings.set(.bool(false), at: ReducedBackgroundsSetting.configPath)
        await settle { harness.room.backdropSelection != nil && GhosttyRuntime.backgroundOverride.material == .glass }
        #expect(harness.room.backdropSelection?.id == Self.work)
        #expect(harness.workspace.backdropSelection == Self.pinned)
        #expect(GhosttyRuntime.backgroundOverride.material == .glass)
        #expect(harness.file.contains(Self.work) && harness.file.contains("glass"), "\(harness.file)")
    }

    /// A live preview of the switch (Settings, the palette) draws it, and leaving the preview
    /// brings the person's background back; nothing is written.
    @Test func previewDrawsThePlainBackgroundAndEndingItRestores() async throws {
        let harness = try await make(reduced: nil)
        defer { tearDown(harness) }
        let row = try #require(SettingsSchema.descriptor(for: ReducedBackgroundsSetting.configPath))
        #expect(harness.settings.preview(row, .bool(true)))
        await settle { harness.room.backdropSelection == nil }
        #expect(harness.room.backdropSelection == nil, "the preview still draws the painting")
        #expect(GhosttyRuntime.backgroundOverride == ReducedBackgroundsSetting.plainWindowBackground,
                "the preview keeps \(GhosttyRuntime.backgroundOverride)")
        harness.settings.endPreview()
        await settle { harness.room.backdropSelection != nil && GhosttyRuntime.backgroundOverride.material == .glass }
        #expect(harness.room.backdropSelection?.id == Self.work)
        #expect(GhosttyRuntime.backgroundOverride.material == .glass)
        #expect(!harness.file.contains("reducedBackgrounds"), "\(harness.file)")
    }
}
