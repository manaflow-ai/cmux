/// The non-sensitive lifecycle state of an iOS Iroh runtime.
public enum CmxIrohClientRuntimeState: Equatable, Sendable {
    /// No endpoint or binding is active.
    case inactive

    /// The endpoint is binding or broker policy is being verified.
    case starting

    /// The endpoint and exact local broker binding are active.
    case active

    /// Ordinary stop has claimed lifecycle ownership and is closing networking.
    case stopping

    /// Sign-out is closing networking and durably queuing binding revocation.
    case signingOut

    /// Networking is closed, but local identity state is retained until revocation is queued.
    case quarantined

    /// Activation failed and local network resources were closed.
    case failed
}
