import Foundation
import WebKit

/// Maps the built-in default profile to `WKWebsiteDataStore.default()` and
/// constructs `WKWebsiteDataStore(forIdentifier:)` for every other profile,
/// bridging the legacy completion-handler wipe to `async`/`await` at this one
/// boundary, conforming WebKit to the ``BrowserProfileWebsiteDataStoreProviding`` seam.
@MainActor
final class BrowserProfileWebsiteDataStoreAdapter: BrowserProfileWebsiteDataStoreProviding {
    var defaultWebsiteDataStore: AnyObject { WKWebsiteDataStore.default() }

    func makeWebsiteDataStore(forProfileID profileID: UUID) -> AnyObject {
        WKWebsiteDataStore(forIdentifier: profileID)
    }

    var allWebsiteDataTypes: [String] { Array(WKWebsiteDataStore.allWebsiteDataTypes()) }

    func removeAllData(ofTypes dataTypes: [String], from store: AnyObject) async {
        guard let store = store as? WKWebsiteDataStore else { return }
        let types = Set(dataTypes)
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}
