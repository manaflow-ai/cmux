import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
import CmuxNextTabs
@testable import CmuxNextSettings
import Foundation
import Testing

/// Change Background… (cx-t2x.4): the picker previews a work in the window as the pointer rests on
/// it, writes nothing until a click, and leaving the picker restores the plain glass default.
@MainActor @Suite(.serialized) struct BackgroundPickerPreviewTests {
    static let gesture = PageCallContext(page: "cmux.settings", userGesture: true)
    static let backgroundKey = "appearance.background"
    static let work = "van-gogh-starry-night"

    struct Harness {
        let settings: SettingsController
        let terminal: TerminalThemeSetting
        let scope: ThemeScope
        let page: SettingsPageProvider
        let url: URL

        var selection: String? { scope.backdropSelection?.id }
        var file: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func make() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-background-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let scope = ThemeScope(level: .room)
        let terminal = TerminalThemeSetting(backdropScope: scope)
        terminal.reload = {}
        terminal.follow(settings)
        return Harness(settings: settings, terminal: terminal, scope: scope, page: SettingsPageProvider(settings: settings), url: url)
    }

    func settle(until done: () -> Bool) async {
        for _ in 0..<400 where !done() { await Task.yield() }
    }

    func call(_ harness: Harness, _ method: String, _ params: [String: JSONValue]) async throws {
        _ = try await harness.page.call(method, params: .object(params), context: Self.gesture)
    }

    @Test func restingOnAWorkPreviewsItAndLeavingRestoresPlainGlass() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        #expect(harness.selection == nil)

        try await call(harness, "cmux.settings.preview", ["key": .string(Self.backgroundKey), "value": .string(Self.work)])
        await settle { harness.selection == Self.work }
        #expect(harness.selection == Self.work)
        #expect(!harness.file.contains("background"))

        try await call(harness, "cmux.settings.preview.end", ["key": .string(Self.backgroundKey)])
        await settle { harness.selection == nil }
        #expect(harness.selection == nil)
    }

    @Test func clickingAWorkKeepsIt() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        try await call(harness, "cmux.settings.preview", ["key": .string(Self.backgroundKey), "value": .string(Self.work)])
        try await call(harness, "cmux.settings.set", ["key": .string(Self.backgroundKey), "value": .string(Self.work)])
        try await call(harness, "cmux.settings.preview.end", ["key": .string(Self.backgroundKey)])
        await settle { harness.settings.snapshot.backdropSelection?.id == Self.work }
        #expect(harness.selection == Self.work)
        #expect(harness.file.contains(Self.work))
    }
}

/// The entry point: a right-click on the window's background (the gaps between panes, an empty
/// workspace) offers Change Background….
@MainActor @Suite struct ChangeBackgroundMenuTests {
    static func titles(_ menu: NSMenu?) -> [String] { menu?.items.map(\.title) ?? [] }

    @Test func rightClickingTheWindowBackgroundOffersChangeBackground() throws {
        let registry = ActionRegistry.standard()
        let view = WorkspaceContentView(layoutView: NSView(), bar: TabStripView(model: TabStripModel()))
        view.backgroundMenu = { registry.makeContextMenu(for: .windowBackground) }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        #expect(Self.titles(view.menu(for: event)).contains("Change Background…"))
    }
}
