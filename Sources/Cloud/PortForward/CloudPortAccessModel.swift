import CmuxCloudBannerCore
import CmuxCloud
import Foundation
import Observation

/// One shared service route. In-app browsers use an authenticated proxy
/// through userspace WireGuard while retaining the VM address and port.
@MainActor
@Observable
final class CloudPortAccessModel {
    enum Phase: Equatable {
        case needsVPN
        case connecting
        case stopping
        case direct
        case proxied(CloudBrowserProxyEndpoint)
        case forwarded(UInt16)
        case failed(String)
        case closed
    }

    private(set) var target: CloudPortForwardTarget
    private(set) var phase: Phase = .needsVPN
    private(set) var tunnelState: CloudTunnelState = .off
    let route: CloudPortAccessRoute
    private var coordinator: CloudTunnelCoordinator?
    private let wake: @MainActor () async throws -> Void
    private let startForward: @MainActor (CloudPortForwardTarget) async throws -> UInt16
    private let stopForward: @MainActor () async -> Void
    private let startBrowserProxy: (@MainActor () async throws -> CloudBrowserProxyEndpoint)?
    private var observation: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = 0

    init(
        target: CloudPortForwardTarget,
        coordinator: CloudTunnelCoordinator?,
        wake: @escaping @MainActor () async throws -> Void,
        startForward: @escaping @MainActor (CloudPortForwardTarget) async throws -> UInt16,
        stopForward: @escaping @MainActor () async -> Void,
        route: CloudPortAccessRoute = .privateNetwork,
        startBrowserProxy: (@MainActor () async throws -> CloudBrowserProxyEndpoint)? = nil
    ) {
        self.target = target
        self.coordinator = coordinator
        self.wake = wake
        self.startForward = startForward
        self.stopForward = stopForward
        self.route = startBrowserProxy == nil ? route : .browserProxy
        self.startBrowserProxy = startBrowserProxy
    }

    var failureMessage: String? {
        switch phase {
        case .failed(let message): return message
        case .needsVPN where route == .privateNetwork:
            if let coordinator, let blocker = CloudTunnelStatus(
                backend: coordinator.backend, state: tunnelState, isPinned: false
            ).privateRouteBlocker { return blocker }
            return String(localized: "cloud.portAccess.privateNetworkRequired", defaultValue: "This HTTPS service requires a private network connection. Run cmux vpn up, then reload.")
        case .closed: return String(localized: "cloud.ports.closed", defaultValue: "Closed")
        default: return nil
        }
    }

    var isReady: Bool {
        switch phase { case .direct, .forwarded, .proxied: return true; default: return false }
    }

    var browserProxy: CloudBrowserProxyEndpoint? {
        if case .proxied(let endpoint) = phase { return endpoint }
        return nil
    }

    var usesBrowserProxy: Bool { route == .browserProxy }

    func connectBrowser(force: Bool = false) {
        if force { retry() } else { connect() }
    }

    var localAddress: String? {
        guard case .forwarded(let port) = phase else { return nil }
        return "127.0.0.1:\(port)"
    }

    /// Starting observation never activates the system tunnel. HTTP is wholly
    /// independent of it; only direct HTTPS routes need its state stream.
    func observe() {
        guard route == .privateNetwork, observation == nil, phase != .closed, let coordinator else { return }
        observation = Task { [weak self] in
            for await state in await coordinator.stateUpdates() {
                guard !Task.isCancelled else { return }
                self?.acceptTunnelState(state)
            }
        }
    }

    func attach(coordinator: CloudTunnelCoordinator) {
        guard self.coordinator == nil, phase != .closed else { return }
        self.coordinator = coordinator
        observe()
    }

    func acceptTunnelState(_ state: CloudTunnelState) {
        guard phase != .closed else { return }
        tunnelState = state
        guard route == .privateNetwork, phase != .stopping else { return }
        if state == .up {
            if phase == .needsVPN { connect() }
        } else if phase == .direct || phase == .connecting {
            generation += 1
            operation?.cancel()
            phase = .needsVPN
        }
    }

    func updateTarget(_ newTarget: CloudPortForwardTarget) {
        guard target != newTarget, phase != .closed else { return }
        target = newTarget
        retry()
    }

    /// Every materialization, restore, and address-bar open uses this action.
    /// Reusing a model cannot restart an in-flight or established connection.
    func connect() {
        guard phase == .needsVPN else { return }
        start()
    }

    func retry() {
        guard phase != .closed, phase != .stopping else { return }
        start()
    }

    private func start() {
        switch route {
        case .browserProxy:
            guard let startBrowserProxy else { return }
            run { [wake] in
                try await wake()
                try Task.checkCancellation()
                return .proxied(try await startBrowserProxy())
            }
        case .loopback:
            run { [wake, startForward, target] in
                try await wake()
                try Task.checkCancellation()
                return .forwarded(try await startForward(target))
            }
        case .privateNetwork:
            guard tunnelState == .up else { return }
            run { [wake] in
                try await wake()
                return .direct
            }
        }
    }

    func stop() async {
        guard phase != .closed, phase != .stopping else { return }
        generation += 1
        operation?.cancel()
        let pending = operation
        operation = nil
        phase = .stopping
        let token = generation
        await pending?.value
        if route == .loopback { await stopForward() }
        guard phase != .closed, generation == token else { return }
        phase = .needsVPN
    }

    func retire() async {
        generation += 1
        let pending = operation
        phase = .closed
        observation?.cancel()
        observation = nil
        operation?.cancel()
        operation = nil
        await pending?.value
        if route == .loopback { await stopForward() }
    }

    func url(for remoteURL: URL) -> URL? {
        switch phase {
        case .direct, .proxied: return CloudPortRoutePolicy().privateURL(remoteURL.absoluteString, address: target.host)
        case .forwarded(let port): return CloudPortRoutePolicy().localURL(rewriting: remoteURL.absoluteString, toLoopbackPort: port)
        default: return nil
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Phase) {
        generation += 1
        let token = generation
        let previous = operation
        previous?.cancel()
        phase = .connecting
        operation = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let phase = try await action()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.phase = phase
                self.operation = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.phase = .failed(CloudMachineLink.errorText(error))
                self.operation = nil
            }
        }
    }
}
