import Foundation

/// Errors raised while resolving cmux's managed Chromium storage namespace.
enum ChromiumOwnedStorageError: Error, Equatable, Sendable, LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String(
                localized: "browser.chromium.storage.applicationSupportUnavailable",
                defaultValue: "Chromium storage is unavailable in Application Support",
                bundle: .module
            )
        }
    }
}
