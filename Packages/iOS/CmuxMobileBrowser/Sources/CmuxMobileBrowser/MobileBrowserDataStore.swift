#if canImport(WebKit)
public import Foundation
public import Observation
public import WebKit

/// Owns the persistent WebKit data store used by phone-local browser panes.
@MainActor
@Observable
public final class MobileBrowserDataStore {
    private let websiteDataStore: WKWebsiteDataStore

    /// Creates a data-store controller.
    /// - Parameter websiteDataStore: The WebKit store to clear. Defaults to the
    ///   app's persistent store.
    public init(websiteDataStore: WKWebsiteDataStore = .default()) {
        self.websiteDataStore = websiteDataStore
    }

    /// Removes cookies, cache, local storage, service workers, and other WebKit
    /// website data from the phone-local browser store.
    public func clearWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            websiteDataStore.removeData(
                ofTypes: types,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}
#endif
