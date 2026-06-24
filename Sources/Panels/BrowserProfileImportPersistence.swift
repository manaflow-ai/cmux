import AppKit
import Foundation
import WebKit
import CmuxBrowser
import CmuxBrowserUI

/// App-side composition that wires the moved ``BrowserDataImportCoordinator``
/// (in `CmuxBrowserUI`) to its app-owned dependencies: the destination profile
/// store (`BrowserProfileStore`, the `BrowserImportProfileResolving` conformer)
/// and the WebKit/history-backed import persistence (`BrowserProfileImportPersistence`).
///
/// The coordinator's `.shared` seam stays in the package, which never names these
/// app types; this installer injects them through the package's instance
/// `configure(profileResolver:importPersistence:)` at app launch so every import
/// entrypoint (Settings, menus, command palette, control socket) drives the same
/// real stores it did before the coordinator was extracted. It registers itself
/// via `+load` for `applicationDidFinishLaunching` so the wiring runs from the
/// composition root without depending on any one entrypoint being hit first.
@MainActor
enum BrowserDataImportComposition {
    static func install() {
        BrowserDataImportCoordinator.shared.configure(
            profileResolver: BrowserProfileStore.shared,
            importPersistence: BrowserProfileImportPersistence()
        )
    }
}

/// Registers ``BrowserDataImportComposition/install()`` to run once at app launch.
/// `+load` only schedules the launch observer; the actual `@MainActor` wiring runs
/// when `applicationDidFinishLaunching` fires. `@objc` keeps the class (and its
/// `+load`) registered with the Objective-C runtime even though no Swift code
/// references it, so the wiring installs without any composition-root call site.
@objc(BrowserDataImportCompositionInstaller)
final class BrowserDataImportCompositionInstaller: NSObject {
    override class func load() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BrowserDataImportComposition.install()
            }
        }
    }
}

/// App-side `BrowserImportPersisting` sink that writes a ``BrowserDataImporter``'s
/// parsed records into the per-profile WebKit cookie store and history store
/// owned by ``BrowserProfileStore``.
///
/// `BrowserDataImporter` lives in `CmuxBrowser` and does all parsing, decryption,
/// and de-duplication; the destinations it feeds (the app's `@MainActor`
/// profile/history stores and `WKHTTPCookieStore`) stay app-side and are reached
/// only through this conformer, so the package never references them.
struct BrowserProfileImportPersistence: BrowserImportPersisting {
    func importCookies(_ cookies: [HTTPCookie], destinationProfileID: UUID) async -> Int {
        guard !cookies.isEmpty else { return 0 }
        let store = await MainActor.run {
            BrowserProfileStore.shared.websiteDataStore(for: destinationProfileID).httpCookieStore
        }
        var importedCount = 0
        for (index, cookie) in cookies.enumerated() {
            if await Self.setCookie(cookie, in: store) {
                importedCount += 1
            }
            if index > 0 && index.isMultiple(of: 50) {
                await Task.yield()
            }
        }
        return importedCount
    }

    func mergeHistory(_ entries: [BrowserHistoryEntry], destinationProfileID: UUID) async -> Int {
        guard !entries.isEmpty else { return 0 }
        return await MainActor.run {
            let historyStore = BrowserProfileStore.shared.historyStore(for: destinationProfileID)
            return historyStore.mergeImportedEntries(entries)
        }
    }

    @MainActor
    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async -> Bool {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume(returning: true)
            }
        }
    }
}
