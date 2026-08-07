enum TestIrohDialResult {
    case connection(TestIrohConnection)
    case failure(TestIrohTransportError)
    /// Suspends until the dial attempt is cancelled, like a peer that never
    /// answers on a stale path hint.
    case hang
}
