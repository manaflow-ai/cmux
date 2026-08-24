public import CMUXMobileCore
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

    /// Whether the connected Mac can list and switch a panel's simulator.
    public var supportsSimulatorDeviceSwitching: Bool {
        supportedHostCapabilities.contains(
            MobileSimulatorStreamCapability.current.devicesIdentifier)
    }

    /// Installed simulators the panel can stream; empty on any failure so
    /// the picker simply hides against older or unreachable hosts.
    public func listSimulatorDevices(
        panelID: String, workspaceID: String
    ) async -> [MobileSimulatorDeviceDescriptor] {
        guard supportsSimulatorDeviceSwitching, let client = remoteClient else { return [] }
        return (try? await client.listMobileSimulatorDevices(
            panelID: panelID, workspaceID: workspaceID)) ?? []
    }

    /// Asks the Mac to switch the panel's simulator. Fire-and-forget: the
    /// v2 stream's own status/config/keyframe flow shows the transition,
    /// and a cold boot outlives any reasonable RPC deadline.
    public func selectSimulatorDevice(
        panelID: String, workspaceID: String, udid: String
    ) async -> Bool {
        guard supportsSimulatorDeviceSwitching, let client = remoteClient else { return false }
        do {
            _ = try await client.selectMobileSimulatorDevice(
                panelID: panelID, workspaceID: workspaceID, udid: udid)
            return true
        } catch {
            return false
        }
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
