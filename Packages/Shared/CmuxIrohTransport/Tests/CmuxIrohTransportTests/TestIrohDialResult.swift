enum TestIrohDialResult {
    case connection(TestIrohConnection)
    case failure(TestIrohTransportError)
    /// A dial that completes only when its task is cancelled.
    case hang
}
