import CMUXMobileCore
public import CmuxMobileRPC
import Foundation

public enum SimulatorStreamV2AccessError: Error, Equatable, Sendable {
    case notConnected
    case routeNotIroh
    case providerUnavailable
}

/// Everything the v2 simulator stream viewer needs from the shell: a way to
/// open the lane against the CURRENT route (evaluated per attach, so a
/// reconnect that changed routes is picked up automatically) and a readiness
/// probe for the lifecycle machine.
public struct SimulatorStreamV2Access: Sendable {
    public let opener:
        @Sendable () async throws -> any MobileSimulatorStreamLaneConnection
    public let transportReady: @MainActor @Sendable () -> Bool
}

extension MobileShellComposite {
    /// Whether the connected Mac serves the v2 dedicated-lane video stream.
    public var supportsSimulatorStreamV2: Bool {
        supportedHostCapabilities.contains(Self.simulatorStreamV2Capability)
            && runtime?.simulatorStreamLaneProvider != nil
            && activeRoute?.kind == .iroh
    }

    public func simulatorStreamV2Access(panelID: String) -> SimulatorStreamV2Access? {
        guard let provider = runtime?.simulatorStreamLaneProvider else { return nil }
        return SimulatorStreamV2Access(
            opener: { @Sendable [weak self] in
                let request = try await MainActor.run {
                    () throws -> CmxByteTransportRequest in
                    guard let self else {
                        throw SimulatorStreamV2AccessError.notConnected
                    }
                    return try self.simulatorStreamV2TransportRequest()
                }
                return try await provider(request, panelID)
            },
            transportReady: { @MainActor [weak self] in
                guard let self else { return false }
                return self.connectionState == .connected
                    && self.activeRoute?.kind == .iroh
                    && self.activeTicket != nil
            }
        )
    }

    private func simulatorStreamV2TransportRequest() throws -> CmxByteTransportRequest {
        guard connectionState == .connected, let activeTicket else {
            throw SimulatorStreamV2AccessError.notConnected
        }
        guard let activeRoute, activeRoute.kind == .iroh else {
            throw SimulatorStreamV2AccessError.routeNotIroh
        }
        return CmxByteTransportRequest(
            route: activeRoute,
            expectedPeerDeviceID: activeTicket.macDeviceID,
            authorizationMode: .transportAdmission,
            sessionPurpose: .featureLane
        )
    }
}
