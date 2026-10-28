import Foundation

/// Errors a device link raises to its provider and mirror sessions.
enum DeviceLinkError: Error, LocalizedError, Equatable {
    case notConnected
    case blocked(String)
    case hostRejected(code: String?, message: String)
    case malformedResponse(String)
    /// The host's status carried no identity: it did not accept this account.
    case identityUnproven
    /// The host answered as a different Mac (or app instance) than the one dialed.
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "devices.link.error.notConnected", defaultValue: "This Mac is not connected right now.")
        case .blocked(let reason):
            return reason
        case .hostRejected:
            return String(localized: "devices.link.error.hostRejected", defaultValue: "The other Mac could not complete this action. Check its connection and try again.")
        case .malformedResponse:
            return String(localized: "devices.link.error.malformed", defaultValue: "The Mac sent an unexpected reply. Update cmux on both Macs and try again.")
        case .identityUnproven:
            return String(localized: "devices.link.error.identityUnproven", defaultValue: "This Mac did not confirm it is signed into your account.")
        case .identityMismatch:
            return String(localized: "devices.link.error.identityMismatch", defaultValue: "A different Mac answered at this address. Pair it again from Settings › Devices.")
        }
    }
}

