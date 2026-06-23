import Foundation
import WebKit
import CmuxBrowser

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
