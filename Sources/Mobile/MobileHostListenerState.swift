import CmuxAuthRuntime
import Foundation

struct MobileHostListenerState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case stopped, starting, ready, retrying }
    var phase: Phase = .stopped
    var boundPort: Int?
    var preferredPort: Int?
    var localSocketAddresses: [String] = []
    var failureDescription: String?

    var isRunning: Bool { phase == .ready }
    var usesEphemeralFallback: Bool {
        guard isRunning, let boundPort, let preferredPort else { return false }
        return boundPort != preferredPort
    }
    var isSettled: Bool { phase != .starting }
}

/// One listener owner supplies both settings state and startup readiness.
@MainActor
protocol MobileHostPairingRuntime: AnyObject, Sendable {
    var listenerState: MobileHostListenerState { get }
    var isNetworkingAllowed: Bool { get }
    func configure(auth: AuthCoordinator)
    func applyManagedNetworkingPolicy() async
    func prepareForStop()
    func stopHost() async
    func foreground() async
    func listenerStateUpdates() -> AsyncStream<MobileHostListenerState>
}
