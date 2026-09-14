import Foundation
import Observation

/// One VM port's shared access state. Browser panes use the authenticated
/// userspace forward when available, while the optional system VPN remains an
/// explicit external-app feature.
@MainActor
@Observable
final class CloudPortAccessModel: Identifiable {
    enum Phase: Equatable {
        case needsVPN
        case connecting
        case stopping
        case direct
        case forwarded(UInt16)
        case failed(String)
        case closed
    }

    let id: CloudHubPortForwarder.Key
    private(set) var target: CloudPortForwardTarget
    private(set) var phase: Phase = .needsVPN
    private(set) var tunnelState: CloudTunnelState = .off
    private(set) var prefersForwarding = false
    let vpn: CloudVPNSetupModel
    private var coordinator: CloudTunnelCoordinator?
    private let wake: @MainActor () async throws -> Void
    private let startForward: @MainActor (CloudPortForwardTarget) async throws -> UInt16
    private let stopForward: @MainActor () async -> Void
    private let canForward: Bool
    private var observation: Task<Void, Never>?
    private var vpnObservation: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var shouldRetryForward = false

    init(
        machineID: String,
        target: CloudPortForwardTarget,
        coordinator: CloudTunnelCoordinator?,
        wake: @escaping @MainActor () async throws -> Void,
        startForward: @escaping @MainActor (CloudPortForwardTarget) async throws -> UInt16,
        stopForward: @escaping @MainActor () async -> Void,
        canForward: Bool = false
    ) {
        id = CloudHubPortForwarder.Key(machineID: machineID, port: target.port)
        self.target = target
        self.coordinator = coordinator
        vpn = CloudVPNSetupModel(coordinator: coordinator)
        self.wake = wake
        self.startForward = startForward
        self.stopForward = stopForward
        self.canForward = canForward
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var isReady: Bool {
        switch phase { case .direct, .forwarded: return true; default: return false }
    }

    var localAddress: String? {
        guard case .forwarded(let port) = phase else { return nil }
        return "127.0.0.1:\(port)"
    }

    /// No coordinator means nothing to observe yet. Leave `observation` unset so
    /// a later ``attach(coordinator:)`` still starts the stream.
    func observe() {
        guard observation == nil, phase != .closed, let coordinator else { return }
        observation = Task { [weak self] in
            for await state in await coordinator.stateUpdates() {
                guard !Task.isCancelled else { return }
                self?.acceptTunnelState(state)
            }
        }
        vpnObservation = Task { [weak self] in
            await self?.vpn.observe()
        }
    }

    /// Providers can materialize before the registry installs its shared
    /// tunnel coordinator. Attach late so those panes can observe VPN state.
    func attach(coordinator: CloudTunnelCoordinator) {
        guard self.coordinator == nil, phase != .closed else { return }
        self.coordinator = coordinator
        // The setup card this pane shows reads the same coordinator; without
        // this it keeps reporting that the build has no VPN extension.
        vpn.attach(coordinator: coordinator)
        observe()
    }

    func acceptTunnelState(_ state: CloudTunnelState) {
        guard phase != .closed else { return }
        tunnelState = state
        guard !prefersForwarding, phase != .stopping else { return }
        if state == .up {
            if phase == .needsVPN || (!prefersForwarding && phase == .failed) { connectDirect() }
        } else {
            generation += 1
            operation?.cancel()
            phase = .needsVPN
            if canForward { forward() }
        }
    }

    func updateTarget(_ newTarget: CloudPortForwardTarget) {
        guard target != newTarget, phase != .closed else { return }
        target = newTarget
        if prefersForwarding { forward() } else if tunnelState == .up { connectDirect() }
    }

    func retry() {
        guard phase != .closed else { return }
        if shouldRetryForward || prefersForwarding { forward() } else if tunnelState == .up { connectDirect() }
    }

    /// This is the sole product action that creates a loopback listener. The
    /// provider invokes it automatically for in-app Cloud browser access.
    func forward() {
        guard phase != .closed, phase != .stopping else { return }
        shouldRetryForward = true
        prefersForwarding = true
        run { [wake, startForward, target] in
            try await wake()
            try Task.checkCancellation()
            return .forwarded(try await startForward(target))
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
        // Wait for an in-flight start to relinquish its listener before close.
        await pending?.value
        await stopForward()
        guard phase != .closed, generation == token else { return }
        shouldRetryForward = false
        prefersForwarding = false
        phase = .needsVPN
        if tunnelState == .up { connectDirect() }
    }

    func retire() async {
        generation += 1
        let pending = operation
        phase = .closed
        shouldRetryForward = false
        observation?.cancel()
        observation = nil
        vpnObservation?.cancel()
        vpnObservation = nil
        operation?.cancel()
        operation = nil
        await pending?.value
        await stopForward()
    }

    func url(for remoteURL: URL) -> URL? {
        switch phase {
        case .direct: return CloudPortRoutePlan.privateURL(remoteURL.absoluteString, address: target.host)
        case .forwarded(let port): return CloudPortRoutePlan.localURL(rewriting: remoteURL.absoluteString, toLoopbackPort: port)
        default: return nil
        }
    }

    private func connectDirect() {
        run { [wake] in
            try await wake()
            return .direct
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
                // A failed userspace forward must leave the system-VPN route
                // available as a recovery path. Reload still retries the
                // failed forward through `shouldRetryForward`.
                self.prefersForwarding = false
                self.phase = .failed(CloudMachineLink.errorText(error))
                self.operation = nil
            }
        }
    }
}
