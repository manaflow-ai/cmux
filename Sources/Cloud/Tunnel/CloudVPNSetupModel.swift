import Foundation
import Observation
import CmuxCloud
import CmuxCloudBannerCore

/// Projects the existing tunnel coordinator. Reading help never activates it.
@MainActor
@Observable
final class CloudVPNSetupModel {
    private var coordinator: CloudTunnelCoordinator?
    private(set) var status: CloudTunnelStatus?
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    init(coordinator: CloudTunnelCoordinator?) {
        self.coordinator = coordinator
    }

    @discardableResult
    func attachIfNeeded(_ coordinator: CloudTunnelCoordinator) -> Bool {
        guard self.coordinator == nil else { return false }
        self.coordinator = coordinator
        status = nil
        return true
    }

    var state: CloudTunnelState { status?.state ?? .off }
    var isSupported: Bool { coordinator?.backend.isNetworkExtension == true }
    var isCheckingStatus: Bool { coordinator == nil || (isSupported && status == nil) }
    var canConnect: Bool { isSupported && status != nil && !isSubmitting && !state.isSettling && state != .up }
    var canDisconnect: Bool { !isSubmitting && (state == .up || state == .starting || state == .awaitingApproval) }

    var unavailableMessage: String? {
        guard coordinator != nil, !isSupported else { return nil }
        return String(localized: "cloud.vpn.setup.unavailable", defaultValue: "This copy of cmux does not include a signed VPN extension. Use a cmux release with Cloud VPN support. Cloud terminals, Ports, and Desktop remain available without the VPN.")
    }

    var statusTitle: String {
        if isCheckingStatus { return String(localized: "cloud.vpn.setup.waiting", defaultValue: "Waiting") }
        if !isSupported { return String(localized: "cloud.vpn.setup.openUnavailable", defaultValue: "Cloud VPN setup is unavailable") }
        switch state {
        case .off: return String(localized: "cloud.vpn.setup.off", defaultValue: "Off")
        case .starting: return String(localized: "cloud.vpn.setup.waiting", defaultValue: "Waiting")
        case .awaitingApproval: return String(localized: "cloud.vpn.setup.waiting", defaultValue: "Waiting")
        case .up: return String(localized: "cloud.vpn.setup.connected", defaultValue: "Connected")
        case .stopping: return String(localized: "cloud.vpn.setup.waiting", defaultValue: "Waiting")
        case .failed: return String(localized: "cloud.vpn.setup.failed", defaultValue: "Needs attention")
        }
    }

    var statusMessage: String? {
        errorMessage ?? unavailableMessage ?? status.flatMap(CloudTunnelBanner.init(status:))?.text
    }

    func prepareForPresentation() { status = nil }

    func observe() async {
        guard let coordinator else { return }
        for await _ in await coordinator.stateUpdates() {
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func refresh() async {
        guard let coordinator else { return }
        let next = await coordinator.status()
        guard !Task.isCancelled else { return }
        status = next
        if next.state == .off {
            let refusal = await coordinator.recordedStartRefusal()
            guard !Task.isCancelled else { return }
            if let refusal { errorMessage = refusal.error.description }
        } else {
            errorMessage = nil
        }
    }

    func connect() async {
        guard canConnect, let coordinator else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        if let refusal = await coordinator.beginUp(pin: true) {
            errorMessage = refusal.error.description
        }
        await refresh()
    }

    func disconnect() async {
        guard canDisconnect, let coordinator else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        await coordinator.requestDown()
        await refresh()
    }
}
