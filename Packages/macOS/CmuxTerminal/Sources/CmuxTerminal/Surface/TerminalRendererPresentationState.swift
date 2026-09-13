/// Mutable bookkeeping for one runtime's host-layer presentation probe.
/// Access is confined to the owning surface's main-actor lifecycle methods.
final class TerminalRendererPresentationState {
    var token: UInt64 = 0
    var inFlightToken: UInt64?
    var baselineFrameSequence: UInt64 = 0
    var recoveryAttempted = false
}
