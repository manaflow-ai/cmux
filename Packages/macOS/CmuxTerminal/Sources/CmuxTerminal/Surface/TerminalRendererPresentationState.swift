import CoreGraphics

/// Mutable bookkeeping for one runtime's host-layer presentation probe.
/// Access is confined to the owning surface's main-actor lifecycle methods.
final class TerminalRendererPresentationState {
    var token: UInt64 = 0
    var inFlightToken: UInt64?
    var recoveryAttempted = false
    /// The last committed drawable geometry observed by the presentation gate.
    /// Phase changes during a live drag do not count as a new drawable.
    var readinessSize: CGSize?
    var readinessBackingScale: CGFloat?
    /// Whether the current renderer lifetime has delivered at least one frame.
    /// This remains true when a shell exits so diagnostics can coexist with
    /// the last usable frame, including after renderer reclamation.
    var didPresentFrame = false
}
