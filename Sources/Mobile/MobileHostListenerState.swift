import CmuxAuthRuntime
import CmuxIrxTransport
import Foundation

struct MobileHostListenerState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case stopped, starting, ready, retrying }
    var phase: Phase = .stopped
    var boundPort: Int?
    var preferredPort: Int?
    var localSocketAddresses: [String] = []
    var failureDescription: String?
    /// Current runtime completed authenticated v2 setup; local relay binding alone is insufficient.
    var hasAuthenticatedRegistration = false

    var isRunning: Bool { phase == .ready }
    var usesEphemeralFallback: Bool {
        guard isRunning, let boundPort, let preferredPort else { return false }
        return boundPort != preferredPort
    }
    var isSettled: Bool { phase != .starting }

    /// Keeps the endpoint's credential-free diagnosis through a pending retry.
    mutating func relayFailed(_ error: any Error) {
        phase = .retrying
        boundPort = nil
        localSocketAddresses = []
        // Only this controlled error type contains a safe user-facing message.
        failureDescription = (error as? IrxEndpointError)?.errorDescription
    }

    mutating func updateReadiness(healthy: Bool, port: Int?, addresses: [String]) {
        phase = healthy ? .ready : .starting
        boundPort = healthy ? port : nil
        localSocketAddresses = healthy ? addresses : []
        if healthy { failureDescription = nil }
    }
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
