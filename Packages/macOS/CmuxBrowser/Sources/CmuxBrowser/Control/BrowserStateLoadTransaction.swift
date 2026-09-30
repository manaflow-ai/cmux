import Foundation

/// The terminal result of restoring browser cookies, navigation, and storage.
public enum BrowserStateLoadTransactionResult: Equatable {
    case loaded
    case cookieWriteFailed
    case navigationFailed(BrowserAutomationNavigationOutcome)
    case storageWriteFailed
}

/// Keeps browser state restoration ordered around the asynchronous WebKit load.
/// Cookies must be present before the request starts, and page storage belongs
/// to the document that actually committed the requested URL.
public enum BrowserStateLoadTransaction {
    /// Restores cookies before navigation and page storage after its commit.
    public static func run(
        hasNavigation: Bool,
        installCookies: () -> Bool,
        navigateAndWait: () -> BrowserAutomationNavigationOutcome?,
        applyStorage: () -> Bool
    ) -> BrowserStateLoadTransactionResult {
        guard installCookies() else { return .cookieWriteFailed }

        if hasNavigation {
            guard let outcome = navigateAndWait() else {
                return .navigationFailed(.notStarted)
            }
            guard outcome == .committed else {
                return .navigationFailed(outcome)
            }
        }

        guard applyStorage() else { return .storageWriteFailed }
        return .loaded
    }
}
