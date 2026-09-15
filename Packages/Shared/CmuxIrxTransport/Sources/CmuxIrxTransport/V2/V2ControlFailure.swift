public import Foundation

/// Stable failures that app policy can handle without parsing exception text.
public enum V2ControlFailure: Error, Sendable, Equatable {
    /// The server rejected one typed operation.
    case server(V2ErrorResponse)
    /// A socket upgrade or HTTP request returned an error status.
    case http(status: Int, retryAfter: TimeInterval?)
    /// A protocol close preserves the server reason after the final typed frame is unavailable.
    case socketClosed(code: Int, reason: String?)
    /// This operation has an active cooldown, independent of other operations.
    case cooldown(schemaID: String, until: Date)
    /// The service has no usable control socket yet.
    case unavailable
    /// One request exceeded its deadline; healthy peer connections are unaffected.
    case requestTimedOut
    /// The service stopped or the request's owning run became obsolete.
    case stopped
    /// Data could not be decoded as a supported generated wire model.
    case invalidWireData
    /// A peer or persisted record belongs to another full identity scope.
    case scopeMismatch
    /// A bounded pending-request or wire-message limit was exceeded.
    case capacityExceeded
    /// A local state write failed; no authentication storage was changed.
    case persistenceFailed
}
