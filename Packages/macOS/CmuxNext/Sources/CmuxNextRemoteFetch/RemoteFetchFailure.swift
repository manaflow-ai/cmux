/// Why a guarded fetch gave no body.
public nonisolated enum RemoteFetchFailure: Error, Equatable, Sendable {
    /// The URL, a name or an address is not allowed.
    case refused
    /// The network, TLS, the reply or the deadline failed.
    case failed
    /// The body is over the cap.
    case tooLarge
}
