import Foundation

/// Owns the pure decode/clamp and error-mapping decisions the Mac's mobile
/// data-plane RPC host makes for a `mobile.attach.ticket.create` request, with
/// no app types.
///
/// Stateless: construct one inline wherever a decision is needed; every instance
/// applies the same rules. The app performs the `[String: Any]` extraction (the
/// v2 `ttl_seconds`/`route_id`/`route_kind`/`scope` reads), the live workspace /
/// surface / terminal-panel resolution, and the async
/// `MobileHostService.createAttachTicket(...)` call, then catches its own
/// `MobileAttachTicketStoreError` and constructs the wire `V2CallResult`; this
/// type owns only the value transforms and the rejection-to-wire-fields mapping
/// between them.
///
/// The `workspace_id`/`terminal_id` presence/UUID gating is owned by the sibling
/// ``MobileHostParamPolicy``; the app runs those gates before resolving and
/// short-circuits on rejection, so they are not re-run here.
public struct MobileAttachTicketRequestCoordinator: Sendable {
    /// Creates the coordinator. It is stateless.
    public init() {}

    /// Clamps a requested ticket TTL to the host's accepted `[30, 3600]` second
    /// window, defaulting to 600 seconds when no value was supplied.
    ///
    /// - Parameter ttlSeconds: The requested `ttl_seconds` value, or `nil` when
    ///   the param was absent or not an integer.
    /// - Returns: The clamped TTL as a `TimeInterval`.
    public func clampedTTL(ttlSeconds: Int?) -> TimeInterval {
        TimeInterval(max(30, min(ttlSeconds ?? 600, 3600)))
    }

    /// Whether the request asks for a Mac-wide (`scope=mac`) ticket.
    ///
    /// A Mac-wide ticket grants access to every workspace on the host instead of
    /// being pinned to the workspace selected at QR-generation time. The match is
    /// case-insensitive, matching the original handler.
    ///
    /// - Parameter scope: The trimmed `scope` param value, or `nil` when absent.
    /// - Returns: `true` when the scope is `mac`.
    public func isMacScope(scope: String?) -> Bool {
        scope?.lowercased() == "mac"
    }

    /// Maps a classified attach-ticket creation failure to its wire fields.
    ///
    /// - Parameters:
    ///   - failure: The classified store failure.
    ///   - routeID: The requested `route_id`, echoed in `data` for
    ///     ``MobileAttachTicketStoreFailure/routeUnavailable``.
    ///   - routeKind: The requested `route_kind`, echoed in `data` for
    ///     ``MobileAttachTicketStoreFailure/routeUnavailable``.
    /// - Returns: The wire `code`/`message`/`data` the app wraps in its result.
    public func errorWire(
        for failure: MobileAttachTicketStoreFailure,
        routeID: String?,
        routeKind: String?
    ) -> MobileAttachTicketErrorWire {
        switch failure {
        case .noRoutes:
            return MobileAttachTicketErrorWire(
                code: "unavailable",
                message: "Mobile host routes are not available yet",
                data: nil
            )
        case .routeUnavailable:
            var data: [String: String] = [:]
            if let routeID {
                data["route_id"] = routeID
            }
            if let routeKind {
                data["route_kind"] = routeKind
            }
            return MobileAttachTicketErrorWire(
                code: "unavailable",
                message: "Requested mobile host route is not available",
                data: data.isEmpty ? nil : data
            )
        case .other(let description):
            return MobileAttachTicketErrorWire(
                code: "internal_error",
                message: "Failed to create mobile attach ticket",
                data: ["error": description]
            )
        }
    }
}
