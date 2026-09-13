import Foundation
import Observation

/// One VM port's explicit access choice. Opening or copying a URL never starts
/// a forward. All browser panes for the port observe this same model.
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
    private let coordinator: CloudTunnelCoordinator?
    private let wake: @MainActor () async throws -> Void
    private let startForward: @MainActor (CloudPortForwardTarget) async throws -> UInt16
    private let stopForward: @MainActor () async -> Void
    private var observation: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = 0

    init(
        machineID: String,
        target: CloudPortForwardTarget,
        coordinator: CloudTunnelCoordinator?,
        wake: @escaping @MainActor () async throws -> Void,
        startForward: @escaping @MainActor (CloudPortForwardTarget) async throws -> UInt16,
        stopForward: @escaping @MainActor () async -> Void
    ) {
        id = CloudHubPortForwarder.Key(machineID: machineID, port: target.port)
        self.target = target
        self.coordinator = coordinator
        vpn = CloudVPNSetupModel(coordinator: coordinator)
        self.wake = wake
        self.startForward = startForward
        self.stopForward = stopForward
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

    func observe() {
        guard observation == nil, phase != .closed else { return }
        let coordinator = coordinator
        observation = Task { [weak self] in
            guard let coordinator else { return }
            for await state in await coordinator.stateUpdates() {
                guard !Task.isCancelled else { return }
                self?.acceptTunnelState(state)
            }
        }
    }

    func acceptTunnelState(_ state: CloudTunnelState) {
        guard phase != .closed else { return }
        tunnelState = state
        guard !prefersForwarding, phase != .stopping else { return }
        if state == .up {
            if phase == .needsVPN { connectDirect() }
        } else {
            generation += 1
            operation?.cancel()
            phase = .needsVPN
        }
    }

    func updateTarget(_ newTarget: CloudPortForwardTarget) {
        guard target != newTarget, phase != .closed else { return }
        target = newTarget
        if prefersForwarding { forward() } else if tunnelState == .up { connectDirect() }
    }

    func retry() {
        guard phase != .closed else { return }
        if prefersForwarding { forward() } else if tunnelState == .up { connectDirect() }
    }

    /// This is the sole product action that creates a loopback listener.
    func forward() {
        guard phase != .closed, phase != .stopping else { return }
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
        prefersForwarding = false
        phase = .needsVPN
        if tunnelState == .up { connectDirect() }
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
                self.phase = .failed(CloudMachineLink.errorText(error))
                self.operation = nil
            }
        }
    }
}
