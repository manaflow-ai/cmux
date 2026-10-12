import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing

/// Shuffle Daily (cx-t2x.5): `appearance.background: "daily"` shows one work of the art set a day.
@MainActor @Suite(.serialized) struct DailyBackgroundTests {
    static let gesture = PageCallContext(page: "cmux.settings", userGesture: true)

    struct Harness {
        let settings: SettingsController
        let terminal: TerminalThemeSetting
        let scope: ThemeScope
        let page: SettingsPageProvider
        let url: URL

        var file: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func make() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-daily-background-\(UUID().uuidString)")
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

    func isArt(_ selection: BackdropSelection?) -> Bool {
        if case .art = selection { return true }
        return false
    }

    @Test func choosingShuffleDailyShowsAWorkOfTheSet() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = try await harness.page.call("cmux.settings.set", params: ["key": "appearance.background", "value": "daily"],
                                        context: Self.gesture)
        await settle { isArt(harness.scope.backdropSelection) }
        #expect(harness.file.contains("\"daily\""))
        #expect(isArt(harness.scope.backdropSelection))
        #expect(harness.settings.snapshot.diagnostics.isEmpty)
    }
}
