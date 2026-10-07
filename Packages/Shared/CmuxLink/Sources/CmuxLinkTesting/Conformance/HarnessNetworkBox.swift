import CmuxLink

/// Holds the current case's network.
actor HarnessNetworkBox {
    private(set) var network: LoopbackNetwork?

    func set(_ network: LoopbackNetwork?) {
        self.network = network
    }
}
