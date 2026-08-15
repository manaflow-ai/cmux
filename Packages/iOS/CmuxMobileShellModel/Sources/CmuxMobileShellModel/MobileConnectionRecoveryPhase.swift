import Foundation

/// Presentation-safe phase for a connection that may be changing transports.
///
/// This is deliberately separate from ``MobileConnectionState``. A workspace
/// can remain mounted and useful while its RPC transport is being replaced.
public enum MobileConnectionRecoveryPhase: Equatable, Sendable {
    case idle
    case probing
    case recovering
    case failed
}
