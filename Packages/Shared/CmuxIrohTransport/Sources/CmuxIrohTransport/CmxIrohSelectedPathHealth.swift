internal import CMUXMobileCore

/// Credential-free local evidence for one exact peer's currently selected path.
///
/// Reading this value performs no dial, broker request, relay mint, or liveness
/// probe. `unknown` means the request cannot be correlated to a current peer,
/// or that peer is still transitioning.
public enum CmxIrohSelectedPathHealth: Equatable, Sendable {
    /// The exact connected peer reports a selected direct, private, or relay path.
    case healthy

    /// The exact correlated peer currently reports no selected path.
    case noPath

    /// Exact peer or selected-path evidence is not currently available.
    case unknown
}

struct CmxIrohSelectedPathHealthClassifier: Sendable {
    func classify(
        request: CmxByteTransportRequest,
        snapshots: [CmxConnectivityPeerID: CmxConnectivityPeerSnapshot],
        observedPaths: [CmxConnectivityPeerID: CmxIrohObservedConnectionPath]
    ) -> CmxIrohSelectedPathHealth {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let snapshot = snapshots[peerID] else {
            return .unknown
        }
        switch snapshot.phase {
        case .connecting:
            return .unknown
        case .disconnected, .failed:
            return .noPath
        case .connected:
            guard let selectedPath = observedPaths[peerID] else {
                return .unknown
            }
            return selectedPath == .unavailable ? .noPath : .healthy
        }
    }
}
