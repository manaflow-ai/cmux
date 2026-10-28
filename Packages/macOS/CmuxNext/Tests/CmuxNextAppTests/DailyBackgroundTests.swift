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
        /// Where the harness posts day and clock changes.
        let center: NotificationCenter
        let scope: ThemeScope
        let page: SettingsPageProvider
        let url: URL
        /// The local day's calendar the harness pins (see ``DailyBackgroundTests/london``).
        let calendar: Calendar

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
        let center = NotificationCenter()
        let calendar = try Self.london()
        terminal.reload = {}
        terminal.notificationCenter = center
        terminal.now = { Self.today }
        terminal.calendar = { calendar }
        terminal.follow(settings)
        return Harness(settings: settings, terminal: terminal, center: center, scope: scope, page: SettingsPageProvider(settings: settings),
                       url: url, calendar: calendar)
    }

    /// The pinned clock: 01:40 BST on 14 Oct 2026, when the macOS 27 run (38491021284) went red.
    static let today = Date(timeIntervalSince1970: 1_791_938_451)

    /// Europe/London in summer time: an hour ahead of its 1 AD local mean time (-0:01:15), so a
    /// day count stepped in 86,400 s from the era's start turns at 01:01:15, not at local midnight.
    static func london() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        return calendar
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
        #expect(harness.scope.backdropSelection == .art(.daily(on: Self.today, calendar: harness.calendar)))
    }

    /// At midnight the window turns to the next day's work without a settings change.
    @Test func theNextDayShowsTheNextWork() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = try await harness.page.call("cmux.settings.set", params: ["key": "appearance.background", "value": "daily"],
                                        context: Self.gesture)
        let (today, calendar) = (Self.today, harness.calendar)
        await settle { harness.scope.backdropSelection == .art(.daily(on: today, calendar: calendar)) }
        let tomorrow = BackdropArt.nextDay(after: today, calendar: calendar).addingTimeInterval(60)
        harness.terminal.now = { tomorrow }
        harness.terminal.showShuffledArt()
        #expect(harness.scope.backdropSelection == .art(.daily(on: tomorrow, calendar: calendar)))
        #expect(harness.scope.backdropSelection != .art(.daily(on: today, calendar: calendar)))
    }

    /// A time zone or clock change re-picks the work for the new local day at once.
    @Test func aClockChangeShowsTheNewDaysWork() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = try await harness.page.call("cmux.settings.set", params: ["key": "appearance.background", "value": "daily"],
                                        context: Self.gesture)
        let (today, calendar) = (Self.today, harness.calendar)
        await settle { harness.scope.backdropSelection == .art(.daily(on: today, calendar: calendar)) }
        let tomorrow = BackdropArt.nextDay(after: today, calendar: calendar).addingTimeInterval(60)
        harness.terminal.now = { tomorrow }
        harness.center.post(name: .NSSystemClockDidChange, object: nil)
        await settle { harness.scope.backdropSelection == .art(.daily(on: tomorrow, calendar: calendar)) }
        #expect(harness.scope.backdropSelection == .art(.daily(on: tomorrow, calendar: calendar)))
        #expect(harness.scope.backdropSelection != .art(.daily(on: today, calendar: calendar)))
    }

    /// Every work shows once before any repeats, and no two days in a row show the same one.
    @Test func theRotationVisitsEveryWorkOncePerCycle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let count = BackdropArt.dailyRotation.count
        let works = (0..<count).map { BackdropArt.daily(on: start.addingTimeInterval(Double($0) * 86_400), calendar: calendar) }
        #expect(Set(works).count == count)
        #expect(zip(works, works.dropFirst()).allSatisfy { $0 != $1 })
        #expect(BackdropArt.daily(on: start.addingTimeInterval(3_600), calendar: calendar) == works[0])
    }

    /// Over two passes of the catalog's size in days, Shuffle Daily shows a work every day.
    @Test func shuffleDailyShowsAWorkEveryDay() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = try await harness.page.call("cmux.settings.set", params: ["key": "appearance.background", "value": "daily"],
                                        context: Self.gesture)
        await settle { isArt(harness.scope.backdropSelection) }
        let calendar = harness.calendar
        var day = Self.today
        var shown: [BackdropArt] = []
        for _ in 0..<(2 * BackdropArt.allCases.count) {
            let now = day
            harness.terminal.now = { now }
            harness.terminal.showShuffledArt()
            if case let .art(art) = harness.scope.backdropSelection { shown.append(art) }
            day = BackdropArt.nextDay(after: now, calendar: calendar).addingTimeInterval(60)
        }
        #expect(shown.count == 2 * BackdropArt.allCases.count)
    }

    /// The daily set is listed by hand: every catalog work in catalog order, no repeats.
    @Test func theDailySetIsTheWholeCatalog() {
        let rotation = BackdropArt.dailyRotation
        #expect(Set(rotation).count == rotation.count)
        #expect(rotation == BackdropArt.allCases)
    }
}
