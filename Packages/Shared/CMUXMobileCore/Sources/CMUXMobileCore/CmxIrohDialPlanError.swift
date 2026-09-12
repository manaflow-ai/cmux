/// Errors raised when a public dial plan places a hint in the wrong phase.
public enum CmxIrohDialPlanError: Error, Equatable, Sendable {
    /// A private or local hint was placed in the first/public phase.
    case privateHintInPublicPhase
    /// A public-internet hint was placed in the private fallback phase.
    case publicHintInPrivatePhase
}
