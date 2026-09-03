public extension CmxIrohHostRuntime {
    /// Returns whether the live authenticated endpoint currently advertises an allowed relay.
    func hasReachableRelay(in allowedRelayURLs: Set<String>) async -> Bool? {
        await activeRelayReachability(in: allowedRelayURLs, connectivityEngine: connectivityEngine)
    }
}
