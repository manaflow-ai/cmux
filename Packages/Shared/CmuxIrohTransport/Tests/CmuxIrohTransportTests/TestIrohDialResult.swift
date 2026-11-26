enum TestIrohDialResult {
    case connection(TestIrohConnection)
    case failure(TestIrohTransportError)
    /// A cancellable dial that does not complete until its caller cancels it.
    case hang
}
