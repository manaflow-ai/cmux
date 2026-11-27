import CmuxAuthRuntime
import Foundation

/// The result of preparing an authenticated browser navigation.
enum BrowserAppSessionRequestOutcome {
    case navigation(BrowserAppSessionNavigation)
    case notAuthenticated
    case cancelled
    case transientFailure
    case failed

    var shouldBeginSignIn: Bool {
        if case .notAuthenticated = self { return true }
        return false
    }

    var shouldRetry: Bool {
        if case .transientFailure = self { return true }
        return false
    }

    static func exchangeFailure(statusCode: Int) -> Self {
        if statusCode == 401 { return .notAuthenticated }
        if (500...599).contains(statusCode) { return .transientFailure }
        return .failed
    }

    static func tokenFailure(_ error: Error) -> Self {
        if let authError = error as? AuthError,
           authError == .unauthorized {
            return .notAuthenticated
        }
        return .transientFailure
    }

    var recoveryAction: BrowserAppSessionRecoveryAction? {
        switch self {
        case .navigation:
            nil
        case .cancelled:
            .isolatedBrowser
        case .notAuthenticated:
            .beginSignIn
        case .transientFailure, .failed:
            .isolatedBrowser
        }
    }
}
