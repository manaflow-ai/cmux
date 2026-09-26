extension RemoteProxyBroker {
    func allocateLoopbackPort() -> Int? {
        loopbackPortAllocator.allocate()
    }
}
