enum TestIrohDialResult {
    case connection(TestIrohConnection)
    case failure(TestIrohTransportError)
}
