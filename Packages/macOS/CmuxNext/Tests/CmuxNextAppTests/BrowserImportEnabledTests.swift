import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
@testable import CmuxNextImportCards
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

    /// Importing a file the person picks never reads another browser: it stays while browser import is off.
    @Test func offKeepsTheFileImports() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try await h.set(false)
        for id: ActionID in ["bookmark.import", "password.importCSV", "browserProfile.removeImportedData"] {
            #expect(h.services.registry.unavailableReason(for: id) != BrowserImportOfferStrings.turnedOff, "\(id) is not turned off")
        }
    }

    /// An Import from Browser window already open when the setting goes off closes, and an import
    /// run started from what is left on screen is refused before it reads anything.
    @Test func offClosesAnOpenImportWindowAndRefusesItsRun() async throws {
        let h = try await make()
        defer { h.tearDown() }
        h.services.onboarding.show(step: .importData)
        #expect(h.services.onboarding.isShowing, "the import window opens while browser import is on")
        try await h.set(false)
        await h.until { !h.services.onboarding.isShowing }
        #expect(!h.services.onboarding.isShowing, "turning browser import off closed the import window")

        let app = AppOnboardingServices(owner: h.services.onboarding)
        #expect(await app.detectBrowsers().isEmpty, "no other browser's folders are read")
        await #expect(throws: BrowserImportTurnedOff.self) {
            _ = try await app.runImport(ImportPlan(items: []), progress: { _ in })
        }
    }

    /// The browser tab's offer: turned off while it shows, it goes, and on again a later page may offer it.
    @Test func offHidesTheOfferAndOnAgainLetsItShowThisLaunch() async throws {
        let h = try await make()
        defer { h.tearDown() }
        let offer = h.services.onboarding.browserImportOffer
        let chrome = BrowserChromeView(tab: WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab())
        offer.show(on: chrome, browsers: [InstalledImportBrowser(browser: .chrome, icon: NSImage())])
        #expect(offer.shownThisLaunch)
        try await h.set(false)
        await h.until { !offer.shownThisLaunch }
        #expect(!offer.shownThisLaunch, "the offer hidden by the setting is not spent for this launch")
    }
}

/// A suggestion scan running when browser import turns off reads nothing more and shows nothing;
/// on again, a new scan starts at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserImportOffScanTests {
    /// A scan the test lets finish.
    @MainActor final class HeldScan {
        private(set) var started = 0
        private var release: [CheckedContinuation<Void, Never>] = []

        func run() async -> [ImportFinding] {
            started += 1
            await withCheckedContinuation { release.append($0) }
            return [ImportFinding(id: "browser.chrome", kind: .browser, browser: .chrome, name: "Chrome", count: 1)]
        }

        func finish() {
            for waiter in release { waiter.resume() }
            release = []
        }
    }

    @Test func turningOffDropsTheScanInFlightAndOnAgainScansAgain() async throws {
        let defaults = try #require(UserDefaults(suiteName: "import-off-scan-\(UUID().uuidString)"))
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger)
        let held = HeldScan()
        center.scanThisMac = { _ in await held.run() }
        center.host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] },
                                      openSettings: { _ in }, importClassic: { _ in nil })
        var landed = false
        center.scan { landed = true }
        while held.started == 0 { await Task.yield() }
        #expect(center.isScanning)

        center.importEnabled = false
        #expect(!center.isScanning, "the scan in flight is dropped")
        held.finish()
        for _ in 0..<50 { await Task.yield() }
        #expect(center.findings.isEmpty, "a dropped scan's findings are not shown")
        #expect(!landed)

        center.importEnabled = true
        await withCheckedContinuation { done in
            center.scan { done.resume() }
            Task { @MainActor in
                while held.started < 2 { await Task.yield() }
                held.finish()
            }
        }
        #expect(held.started == 2, "on again, a new scan ran")
        #expect(center.findings.count == 1)
    }
}
