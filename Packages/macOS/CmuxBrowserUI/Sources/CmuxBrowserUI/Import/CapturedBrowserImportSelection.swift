#if DEBUG
import Foundation

/// The JSON shape ``BrowserDataImportCoordinator`` writes when a UI test runs in
/// `capture-only` import mode: the chosen browser, destination mode, scope,
/// domain filters, and per-entry source/destination summary, asserted by
/// browser-import UI tests instead of running a real import.
struct CapturedBrowserImportSelection: Encodable {
    struct Entry: Encodable {
        let sourceProfiles: [String]
        let destinationKind: String
        let destinationName: String
    }

    let browserName: String
    let mode: String
    let scope: String
    let domainFilters: [String]
    let entries: [Entry]
}
#endif
