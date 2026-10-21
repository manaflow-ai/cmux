import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// A rotating background like macOS's (Leo, 2026-10-20): Shuffle turns to its next picture on an
/// interval (`appearance.backgroundRotation`: every 15 minutes, hour or day), through the
/// paintings (`daily`) or the pictures in a folder (`folder:<absolute path>`).
@MainActor @Suite(.serialized) struct BackgroundRotationTests {
    struct Harness {
        let settings: SettingsController
        let terminal: TerminalThemeSetting
        let center: NotificationCenter
        let scope: ThemeScope
        let directory: URL
        let calendar: Calendar

        func write(_ json: String) async throws {
            try Data(json.utf8).write(to: directory.appending(path: "cmux.json"))
            await settings.reload()
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    /// The pinned clock: 01:40 BST on 14 Oct 2026.
    static let today = Date(timeIntervalSince1970: 1_791_938_451)

    func make() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-background-rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let scope = ThemeScope(level: .room)
        let terminal = TerminalThemeSetting(backdropScope: scope)
        let center = NotificationCenter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        terminal.reload = {}
        terminal.notificationCenter = center
        terminal.now = { Self.today }
        terminal.calendar = { [calendar] in calendar }
        terminal.follow(settings)
        return Harness(settings: settings, terminal: terminal, center: center, scope: scope, directory: directory, calendar: calendar)
    }

    func settle(until done: () -> Bool) async {
        for _ in 0..<400 where !done() { await Task.yield() }
    }

    /// The pictures shown at each of `steps` moments `every` apart (a clock change re-picks at once).
    func shown(_ harness: Harness, steps: Int, every seconds: TimeInterval) async -> [BackdropSelection?] {
        var shown: [BackdropSelection?] = []
        for step in 0..<steps {
            let now = Self.today.addingTimeInterval(Double(step) * seconds)
            harness.terminal.now = { now }
            harness.center.post(name: .NSSystemClockDidChange, object: nil)
            for _ in 0..<50 { await Task.yield() }
            shown.append(harness.scope.backdropSelection)
        }
        return shown
    }

    /// Every hour: the paintings turn on the hour, not once a day.
    @Test func hourlyShuffleTurnsThePaintingEachHour() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        try await harness.write(#"{"appearance": {"background": "daily", "backgroundRotation": "hourly"}}"#)
        await settle { harness.scope.backdropSelection != nil }
        let pictures = await shown(harness, steps: 4, every: 3_600)
        #expect(pictures.allSatisfy { $0 != nil })
        #expect(zip(pictures, pictures.dropFirst()).allSatisfy { $0 != $1 }, "\(pictures.map { $0?.id ?? "-" })")
        #expect(harness.settings.snapshot.diagnostics.isEmpty)
    }

    /// Unset, Shuffle still turns once a day, as Shuffle Daily always did.
    @Test func unsetRotationStaysDaily() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        try await harness.write(#"{"appearance": {"background": "daily"}}"#)
        await settle { harness.scope.backdropSelection != nil }
        #expect(harness.scope.backdropSelection == .art(.daily(on: Self.today, calendar: harness.calendar)))
    }

    /// A folder: its pictures take turns, each once before any repeats; other files are skipped.
    @Test func aFolderShufflesItsPictures() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        let folder = harness.directory.appending(path: "Pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["a.png", "b.jpg", "c.heic"]
        for name in names + ["notes.txt"] { try Data([0]).write(to: folder.appending(path: name)) }
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        try await harness.write(#"{"appearance": {"background": "folder:\#(path)", "backgroundRotation": "15m"}}"#)
        await settle { harness.scope.backdropSelection != nil }
        #expect(harness.settings.snapshot.diagnostics.isEmpty)
        let pictures = await shown(harness, steps: 3, every: 900)
        let files = Set(pictures.compactMap { picture -> String? in
            if case .file(let file) = picture { return URL(fileURLWithPath: file).lastPathComponent }
            return nil
        })
        #expect(files == Set(names))
    }
}
