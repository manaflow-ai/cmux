extension RemoteProxyBroker {
    /// Binds an ephemeral loopback TCP socket to discover a free port.
    static func allocateLoopbackPort() -> Int? {
        LoopbackPortAllocator.allocate()
    }
}
