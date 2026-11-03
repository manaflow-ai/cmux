import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextPalette
@testable import CmuxNextSettings
import Foundation
import Testing

/// Going back to an unset `browser.hibernation` (never discard, hidden pages only freeze) from a
/// written value, through the Settings page's Reset (its "Never Discard" menu entry) and the
/// palette's "Never Discard" option: the key leaves cmux.json, automatic discards stop, and both
/// show the unset entry as the current one.
@MainActor @Suite(.serialized) struct BrowserHibernationUnsetChoiceTests {
    static let gesture = PageCallContext(page: "cmux.settings", userGesture: true)
    static let key = "browser.hibernation"
    static let unsetLabel = "Never Discard"

    struct Harness {
        let settings: SettingsController
        let page: SettingsPageProvider
        let palette: SettingsPaletteSource
        let url: URL

        var file: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        var stored: JSONValue? { settings.fileRoot.value(at: BrowserHibernationSetting.configPath) }

        /// The Settings page's row: its value and whether it shows Reset.
        func pageRow() async throws -> (value: JSONValue?, customized: Bool?) {
            let params: JSONValue = .object(["section": .string("browser")])
            let rows: JSONValue = try await page.call("cmux.settings.list", params: params, context: BrowserHibernationUnsetChoiceTests.gesture)
            let key = BrowserHibernationUnsetChoiceTests.key
            let items: [JSONValue] = rows.arrayValue ?? []
            let row: JSONValue? = items.first(where: { (item: JSONValue) -> Bool in item["key"]?.stringValue == key })
            let value: JSONValue? = row?["value"]
            return (value == JSONValue.null ? nil : value, row?["customized"]?.boolValue)
        }

        /// The palette row's shown value and its current option.
        func paletteRow() -> (value: String, current: [String]) {
            guard let row = palette.rows.first(where: { $0.id == BrowserHibernationUnsetChoiceTests.key }) else { return ("", []) }
            guard case .options(let options, _) = row.kind else { return (row.value, []) }
            return (row.value, options.filter(\.isCurrent).map(\.title))
        }

        func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func make(_ json: String) async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-hibernation-unset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return Harness(settings: settings, page: SettingsPageProvider(settings: settings),
                       palette: SettingsPaletteSource(settings: settings, themeColors: { [] }), url: url)
    }

    /// Waits up to 5 s for a write that lands off this task.
    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func unsetShowsNeverDiscardOnThePageAndThePalette() async throws {
        let harness = try await make("{}")
        defer { harness.tearDown() }
        let row = try await harness.pageRow()
        #expect(row.value == nil)
        #expect(row.customized == false)
        let palette = harness.paletteRow()
        #expect(palette.value == Self.unsetLabel)
        #expect(palette.current == [Self.unsetLabel])
        #expect(!harness.settings.snapshot.browserHibernation.discardsAutomatically)
    }

    @Test func anExplicitModerateShowsAfter30MinutesAndReset() async throws {
        let harness = try await make(#"{"browser": {"hibernation": "moderate"}}"#)
        defer { harness.tearDown() }
        let row = try await harness.pageRow()
        #expect(row.value == .string("moderate"))
        #expect(row.customized == true, "Reset shows: it returns to never discarding")
        #expect(harness.paletteRow().current == ["After 30 Minutes"])
        #expect(harness.settings.snapshot.browserHibernation.discardsAutomatically)
    }

    @Test(arguments: [#"{"browser": {"hibernation": 45}}"#, #"{"browser": {"hibernation": "moderate"}}"#])
    func resetOnThePageReturnsToUnset(_ json: String) async throws {
        let harness = try await make(json)
        defer { harness.tearDown() }
        #expect(harness.settings.snapshot.browserHibernation.discardsAutomatically)
        _ = try await harness.page.call("cmux.settings.reset", params: ["key": .string(Self.key)], context: Self.gesture)
        await settle { harness.stored == nil }
        #expect(harness.stored == nil, "the key left cmux.json: \(harness.file)")
        #expect(!harness.settings.snapshot.browserHibernation.discardsAutomatically)
        let row = try await harness.pageRow()
        #expect(row.value == nil)
        #expect(row.customized == false)
    }

    @Test func neverDiscardOnThePaletteReturnsAWrittenTimeoutToUnset() async throws {
        let harness = try await make(#"{"browser": {"hibernation": 45}}"#)
        defer { harness.tearDown() }
        #expect(harness.paletteRow().current.isEmpty)
        harness.palette.commit(row: Self.key, option: "reset")
        #expect(harness.paletteRow().current == [Self.unsetLabel], "the row shows it at once")
        await settle { harness.stored == nil }
        #expect(harness.stored == nil, "the key left cmux.json: \(harness.file)")
        #expect(!harness.settings.snapshot.browserHibernation.discardsAutomatically)
        #expect(harness.paletteRow().current == [Self.unsetLabel])
    }

    @Test func pickingATimeoutStillWritesItAndDiscards() async throws {
        let harness = try await make("{}")
        defer { harness.tearDown() }
        harness.palette.commit(row: Self.key, option: #""aggressive""#)
        await settle { harness.stored != nil }
        #expect(harness.stored == .string("aggressive"))
        #expect(harness.settings.snapshot.browserHibernation.discardsAutomatically)
        #expect(harness.paletteRow().current == ["After 10 Minutes"])
    }
}
