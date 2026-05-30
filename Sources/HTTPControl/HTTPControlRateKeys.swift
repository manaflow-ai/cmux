import CmuxTerminalAccess
import Foundation

/// Stable string keys for the shared
/// ``CmuxTerminalAccess/RateLimiter`` per D10.
///
/// The cmux HTTP transport rate-limits per `(surface, kind)` pair so a
/// runaway script holding one surface cannot starve writes to others.
/// Phase 2 adds the per-connection stream-open bucket as a sibling key
/// on the same limiter.
///
/// The key format matches ``SurfaceListJSON/encode(_:)`` so wire-side
/// audit tooling can join rate-limit telemetry against the surface
/// list response without an extra mapping layer.
public enum HTTPControlRateKeys {
    /// Key for the per-surface write bucket consumed by every
    /// ``CmuxTerminalAccess/TerminalAccessService/writeInput(_:)``
    /// call.
    public static func write(for handle: SurfaceHandle) -> String {
        "surface:\(SurfaceListJSON.encode(handle))#write"
    }

    /// Key for the per-surface stream-open bucket consumed in Phase 2
    /// when a client opens an SSE stream against a surface.
    public static func streamOpen(for handle: SurfaceHandle) -> String {
        "surface:\(SurfaceListJSON.encode(handle))#stream-open"
    }
}
