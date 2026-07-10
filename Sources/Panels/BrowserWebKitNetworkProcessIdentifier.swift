import WebKit

@MainActor
enum BrowserWebKitNetworkProcessIdentifier {
    static func current(for websiteDataStore: WKWebsiteDataStore) -> Int? {
        // The public proxy setter clears only the live NetworkProcess and leaves
        // WebKit's retained explicit payload intact. cmux already uses guarded
        // WebKit process selectors for diagnostics; this one lets a direct route
        // be re-cleared exactly once when that process is replaced.
        let selector = NSSelectorFromString("_networkProcessIdentifier")
        guard websiteDataStore.responds(to: selector),
              let implementation = websiteDataStore.method(for: selector) else {
            return nil
        }
        typealias IdentifierFunction = @convention(c) (AnyObject, Selector) -> Int32
        let identifier = unsafeBitCast(implementation, to: IdentifierFunction.self)(websiteDataStore, selector)
        return identifier > 0 ? Int(identifier) : nil
    }
}
