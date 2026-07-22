public import Foundation

/// Errors produced by extension enable, remove, revoke, and update actions.
public enum BrowserWebExtensionManagementError: LocalizedError, Equatable {
    case extensionNotFound
    case stateChanged
    case updateUnavailable
    case upToDate

    public var errorDescription: String? {
        switch self {
        case .extensionNotFound:
            return String(
                localized: "browser.extensions.management.notFound",
                defaultValue: "The extension is no longer installed."
            )
        case .stateChanged:
            return String(
                localized: "browser.extensions.management.stateChanged",
                defaultValue: "The extension changed while this action was running. Try again."
            )
        case .updateUnavailable:
            return String(
                localized: "browser.extensions.management.updateUnavailable",
                defaultValue: "This extension does not have a trusted automatic update source."
            )
        case .upToDate:
            return String(
                localized: "browser.extensions.management.upToDate",
                defaultValue: "This extension is up to date."
            )
        }
    }
}
