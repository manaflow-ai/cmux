import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextImportSuggestions
@testable import CmuxNextSettings
import Foundation
import Testing

/// `browser.import.enabled` (on by default): off, cmux's Import from Browser entry points leave the
/// palette, the File menu and the context menus, the import tool window does not open, the import
/// suggestion cards (Settings › Import) are off and Keep in Sync pauses. On again,
/// every one is back.
@MainActor @Suite(.serialized) struct BrowserImportEnabledTests {
    /// The entry points the setting hides: the menu items and palette actions, and the card verbs.
    static let entryPoints: [ActionID] = [
        "importFromBrowser", "bookmark.importFromBrowser", "browser.importFromFiles", "browser.importCookies",
        "import.open", "import.card", "import.suggest", "import.list",
    ]

    struct Harness {
        let services: AppServices
        let settings: SettingsController
        let url: URL

        func tearDown() {
            services.onboarding.controller?.window?.close()
            // The cards are app-wide: the next test starts with them on.
            ImportSuggestionsCenter.shared.importEnabled = true
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        /// Waits for `condition` up to a deadline: the settings write and reload run on other tasks.
        func until(_ condition: () -> Bool, within timeout: Duration = .seconds(10)) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// Writes the setting and waits until the snapshot and the cards it drives both follow it.
        func set(_ on: Bool) async throws {
            try await settings.set(.bool(on), at: BrowserImportSetting.configPath)
            await until { settings.snapshot.browserImportEnabled == on && ImportSuggestionsCenter.shared.importEnabled == on }
            #expect(settings.snapshot.browserImportEnabled == on)
            #expect(ImportSuggestionsCenter.shared.importEnabled == on)
        }

        /// Waits for Keep in Sync (an actor) to be paused or not.
        func syncPaused(_ paused: Bool, within timeout: Duration = .seconds(10)) async -> Bool {
            let sync = services.onboarding.historySync
            let deadline = ContinuousClock.now + timeout
            while await sync.isPaused != paused, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await sync.isPaused == paused
        }

        /// Whether the File menu shows `id` (a hidden item is validated off and hidden, as AppKit does on open).
        func fileMenuShows(_ id: ActionID) -> Bool {
            guard let item = services.registry.makeMainMenuItems(for: .file).first(where: { $0.representedObject as? String == id.rawValue })
            else { return false }
            _ = (item.target as? NSMenuItemValidation)?.validateMenuItem(item)
            return !item.isHidden
        }

        /// Whether a browser page's right-click menu lists `id`.
        func contextMenuShows(_ id: ActionID) -> Bool {
            services.registry.makeContextMenu(for: .browserPage, entries: [.action(id)]).items.contains { !$0.isSeparatorItem }
        }
    }

    func make() async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-browser-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return Harness(services: services, settings: settings, url: url)
    }

    @Test func onByDefaultEveryEntryPointIsOffered() async throws {
        let h = try await make()
        defer { h.tearDown() }
        #expect(h.settings.snapshot.browserImportEnabled)
        for id in Self.entryPoints {
            #expect(h.services.registry.isAvailable(id), "\(id) is offered by default")
        }
        #expect(h.fileMenuShows("importFromBrowser"))
        #expect(h.contextMenuShows("importFromBrowser"))
        #expect(ImportSuggestionsCenter.shared.isEnabled)
    }

    @Test func offHidesTheEntryPointsAndOnBringsThemBack() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try await h.set(false)

        for id in Self.entryPoints {
            #expect(!h.services.registry.isAvailable(id), "\(id) is hidden while browser import is off")
            #expect(!h.services.registry.canPerform(id), "\(id) does not run while browser import is off")
        }
        #expect(!h.fileMenuShows("importFromBrowser"), "File > Import from Browser… is hidden")
        #expect(!h.fileMenuShows("bookmark.importFromBrowser"), "File > Import Bookmarks from Browser… is hidden")
        #expect(!h.contextMenuShows("importFromBrowser"), "the browser context menu leaves out Import from Browser…")
        #expect(!h.services.registry.perform("importFromBrowser", invocation: ActionInvocation(origin: .user)))
        // The import tool window (onboarding's import step) does not open, whoever asks.
        h.services.onboarding.show(step: .importData)
        #expect(!h.services.onboarding.isShowing, "the import window stays closed")
        // Every run says why: the palette's subtitle and the socket's `unavailable` reason.
        #expect(h.services.registry.unavailableReason(for: "importFromBrowser") == BrowserImportOfferStrings.turnedOff)
        // The import suggestion cards are off in Settings › Import, and a card
        // still on screen starts nothing.
        #expect(!ImportSuggestionsCenter.shared.isEnabled)
        #expect(ImportSuggestionsCenter.shared.settingsJSON == .null)
        #expect(ImportSuggestionsCenter.shared.list().cards.isEmpty)
        #expect(throws: (any Error).self) { try ImportSuggestionsCenter.shared.perform("chrome", .start) }
        // Keep in Sync stops re-reading other browsers' history.
        #expect(await h.syncPaused(true), "Keep in Sync is paused while browser import is off")

        // Already-imported data stays: Remove Imported Data is still offered.
        #expect(h.services.registry.isAvailable("browserProfile.removeImportedData"))

        try await h.set(true)
        for id in Self.entryPoints {
            #expect(h.services.registry.isAvailable(id), "\(id) is back")
        }
        #expect(h.fileMenuShows("importFromBrowser"))
        #expect(ImportSuggestionsCenter.shared.isEnabled)
        #expect(await h.syncPaused(false), "Keep in Sync watches again")
    }
}
