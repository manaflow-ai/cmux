import Foundation
import Observation

/// UI projection only. Opening the guide observes status without enrolling or
/// activating the extension; the existing coordinator owns the connection.
@MainActor
@Observable
final class CloudVPNSetupModel {
    let tunnelStatus = CloudTunnelStatusModel()
    private let coordinator: CloudTunnelCoordinator?
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    init(coordinator: CloudTunnelCoordinator?) {
        self.coordinator = coordinator
    }

    var state: CloudTunnelState { tunnelStatus.status?.state ?? .off }

    var unavailableMessage: String? {
        guard coordinator?.backend.isNetworkExtension == true else {
            return String(localized: "cloud.vpn.setup.unavailable", defaultValue: "This copy of cmux does not include a signed VPN extension. Use a cmux release with Cloud VPN support. Cloud terminals, Ports, and Desktop remain available without the VPN.")
        }
        return nil
    }

    var canConnect: Bool {
        unavailableMessage == nil && !isSubmitting && !state.isSettling && state != .up
    }

    func observe() async {
        guard let coordinator else { return }
        for await _ in await coordinator.stateUpdates() {
            await refresh()
        }
    }

    func refresh() async {
        guard let coordinator else { return }
        await tunnelStatus.refresh(coordinator)
        if state == .off, let refusal = await coordinator.recordedStartRefusal() {
            errorMessage = refusal.error.description
        } else if state == .starting || state == .up {
            errorMessage = nil
        }
    }

    func connect() async {
        guard canConnect, let coordinator else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        // Admission can fail before the coordinator enters starting. Keep that
        // refusal visible instead of silently leaving the pane in its off state.
        if let refusal = await coordinator.beginUp(pin: true) {
            errorMessage = refusal.error.description
        }
        await tunnelStatus.refresh(coordinator)
    }

    func disconnect() async {
        guard !isSubmitting, let coordinator else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        await coordinator.requestDown()
        await tunnelStatus.refresh(coordinator)
    }
}
