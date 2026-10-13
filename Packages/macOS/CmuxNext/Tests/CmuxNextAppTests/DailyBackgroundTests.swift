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
        #expect(harness.scope.backdropSelection == .art(.daily(on: Date())))
    }

    /// At midnight the window turns to the next day's work without a settings change.
    @Test func theNextDayShowsTheNextWork() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = try await harness.page.call("cmux.settings.set", params: ["key": "appearance.background", "value": "daily"],
                                        context: Self.gesture)
        let today = Date()
        await settle { harness.scope.backdropSelection == .art(.daily(on: today)) }
        let tomorrow = BackdropArt.nextDay(after: today).addingTimeInterval(60)
        harness.terminal.now = { tomorrow }
        harness.terminal.showDailyArt()
        #expect(harness.scope.backdropSelection == .art(.daily(on: tomorrow)))
        #expect(harness.scope.backdropSelection != .art(.daily(on: today)))
    }

    /// A time zone or clock change re-picks the work for the new local day at once.
    @Test func aClockChangeShowsTheNewDaysWork() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = try await harness.page.call("cmux.settings.set", params: ["key": "appearance.background", "value": "daily"],
                                        context: Self.gesture)
        let today = Date()
        await settle { harness.scope.backdropSelection == .art(.daily(on: today)) }
        let tomorrow = BackdropArt.nextDay(after: today).addingTimeInterval(60)
        harness.terminal.now = { tomorrow }
        // global-notice-allow: the system's clock-change notice, which the theme observes on .default; posted on the main actor, in a serialized suite.
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        await settle { harness.scope.backdropSelection == .art(.daily(on: tomorrow)) }
        #expect(harness.scope.backdropSelection == .art(.daily(on: tomorrow)))
    }

    /// Every work shows once before any repeats, and no two days in a row show the same one.
    @Test func theRotationVisitsEveryWorkOncePerCycle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let count = BackdropArt.allCases.count
        let works = (0..<count).map { BackdropArt.daily(on: start.addingTimeInterval(Double($0) * 86_400), calendar: calendar) }
        #expect(Set(works).count == count)
        #expect(zip(works, works.dropFirst()).allSatisfy { $0 != $1 })
        #expect(BackdropArt.daily(on: start.addingTimeInterval(3_600), calendar: calendar) == works[0])
    }
}
