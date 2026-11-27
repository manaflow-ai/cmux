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
/// to the document that actually committed the requested URL. The saved frame
/// selection names a frame of that document, so it comes last and only when
/// everything before it succeeded.
public struct BrowserStateLoadTransaction: Sendable {
    public init() {}

    /// Restores cookies before navigation, then page storage and frame selection after its commit.
    public func run(
        hasNavigation: Bool,
        restoreFrameSelection: () -> Void,
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
        restoreFrameSelection()
        return .loaded
    }
}
