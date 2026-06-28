import Foundation

/// Classifies the outcome of the Mac host's attach-ticket creation as the
/// mobile data plane's RPC host needs to map it to a wire error.
///
/// The app catches its own `MobileAttachTicketStoreError` (an app-side `Error`)
/// off the live `createAttachTicket` call and classifies it into one of these
/// cases; ``MobileAttachTicketRequestCoordinator/errorWire(for:routeID:routeKind:)``
/// then maps the case to the wire code/message/data. The store error and the
/// `V2CallResult` both stay app-side; this enum is only the pure decision
/// between the catch and the wire result.
public enum MobileAttachTicketStoreFailure: Sendable, Equatable {
    /// No mobile host routes exist yet. Mapped to `unavailable` / "Mobile host
    /// routes are not available yet".
    case noRoutes

    /// The requested route is not available. Mapped to `unavailable` /
    /// "Requested mobile host route is not available", echoing the requested
    /// `route_id`/`route_kind` in `data`.
    case routeUnavailable

    /// Any other thrown error. Mapped to `internal_error` / "Failed to create
    /// mobile attach ticket", carrying the `String(describing:)` of the error.
    case other(String)
}
