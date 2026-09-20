import Foundation

/// The result of one successful listening-port command on a Cloud machine.
struct CloudPortScanResult: Equatable, Sendable {
    let ports: [Int]
    let hadListeners: Bool
    let hadLoopbackOnlyListeners: Bool

    var emptyReason: CloudPortDiscoveryState.EmptyReason? {
        guard ports.isEmpty else { return nil }
        return hadLoopbackOnlyListeners ? .loopbackOnly : .noListeningService
    }
}
