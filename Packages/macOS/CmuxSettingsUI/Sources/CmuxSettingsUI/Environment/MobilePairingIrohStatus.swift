import Foundation

/// The irx endpoint state shown alongside the Mac's mobile pairing listener.
public enum MobilePairingIrohStatus: String, Sendable, Equatable {
    /// No authenticated irx endpoint is requested.
    case inactive
    /// The endpoint is establishing its broker binding or relay link.
    case starting
    /// The endpoint is bound and available to iPhone.
    case active
    /// A transient broker failure is waiting on bounded backoff.
    case retrying
    /// A non-retryable activation failure stopped the endpoint.
    case failed
    /// The account session was rejected and sign-in is required.
    case reauthenticationRequired = "reauthentication_required"
}
