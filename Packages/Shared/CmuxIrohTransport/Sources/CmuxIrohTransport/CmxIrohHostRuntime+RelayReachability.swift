public extension CmxIrohHostRuntime {
    /// Returns whether the live authenticated endpoint currently advertises an allowed relay.
    func hasReachableRelay(in allowedRelayURLs: Set<String>) async -> Bool? {
        guard !allowedRelayURLs.isEmpty,
              lifecyclePhase == .active,
              let connectivityEngine,
              let address = try? await connectivityEngine.endpointAddress() else {
            return nil
        }
        return address.pathHints.contains {
            $0.kind == .relayURL && allowedRelayURLs.contains($0.value)
        }
    }
}
