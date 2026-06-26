public import Foundation

/// Why a portal-binding request was rejected by the hosted view's acceptance guard.
///
/// A pure classifier over the binding guard inputs: the expected surface
/// identity/generation the caller asked to bind, and the hosted view's actual
/// `(surfaceId, generation, state)` snapshot at bind time. The `wireValue`
/// strings are the DEBUG telemetry tokens consumed by `portal.bind.blocked`
/// logging and the blocked-reason histogram, so they are byte-stable.
public enum PortalBindBlockReason: Sendable, Equatable {
    /// The hosted view reports no surface identity at all.
    case missingSurface
    /// The hosted view is not in the `"live"` state; carries the actual state token.
    case unexpectedState(String)
    /// A specific surface was expected but the hosted view reports a different one.
    case surfaceMismatch
    /// A specific generation was expected but the hosted view reports a different one.
    case generationMismatch
    /// None of the above matched; the guard rejected for an unclassified reason.
    case guardRejected

    /// Classifies a rejected binding from the expected identity and the hosted
    /// view's actual snapshot, matching the legacy guard precedence exactly.
    public init(
        expectedSurfaceId: UUID?,
        expectedGeneration: UInt64?,
        actual: (surfaceId: UUID?, generation: UInt64?, state: String)
    ) {
        if actual.surfaceId == nil {
            self = .missingSurface
        } else if actual.state != "live" {
            self = .unexpectedState(actual.state)
        } else if let expectedSurfaceId, actual.surfaceId != expectedSurfaceId {
            self = .surfaceMismatch
        } else if let expectedGeneration, actual.generation != expectedGeneration {
            self = .generationMismatch
        } else {
            self = .guardRejected
        }
    }

    /// The byte-stable telemetry token used in `portal.bind.blocked` logs and the
    /// blocked-reason histogram.
    public var wireValue: String {
        switch self {
        case .missingSurface:
            return "missingSurface"
        case .unexpectedState(let state):
            return "state_\(state)"
        case .surfaceMismatch:
            return "surfaceMismatch"
        case .generationMismatch:
            return "generationMismatch"
        case .guardRejected:
            return "guardRejected"
        }
    }
}
