import Foundation
import CmuxBrowser

/// A no-op ``BrowserImportPersisting`` sink used by ``BrowserDataImportCoordinator``
/// only when the app has not called
/// ``BrowserDataImportCoordinator/configure(profileResolver:importPersistence:)``.
///
/// It exists so the coordinator always constructs and runs a ``BrowserDataImporter``
/// (preserving the pre-extraction control flow) even before the app wires its
/// real WebKit/history-backed persistence. It persists nothing.
struct EmptyBrowserImportPersisting: BrowserImportPersisting {
    func importCookies(_ cookies: [HTTPCookie], destinationProfileID: UUID) async -> Int { 0 }

    func mergeHistory(_ entries: [BrowserHistoryEntry], destinationProfileID: UUID) async -> Int { 0 }
}
