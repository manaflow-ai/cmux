extension RemoteProxyBroker {
    /// Binds an ephemeral loopback TCP socket to discover a free port.
    func allocateLoopbackPort() -> Int? {
        loopbackPortAllocator.allocate()
    }
}
