/// The non-sensitive lifecycle state of an iOS Iroh runtime.
public enum CmxIrohClientRuntimeState: Equatable, Sendable {
    /// No endpoint or binding is active.
    case inactive

    /// The endpoint is binding or broker policy is being verified.
    case starting

    /// The endpoint and exact local broker binding are active.
    case active

    /// Activation failed and local network resources were closed.
    case failed
}
