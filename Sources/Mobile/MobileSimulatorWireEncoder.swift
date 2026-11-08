import CMUXMobileCore
import CmuxSimulator
import Foundation

@MainActor
struct MobileSimulatorWireEncoder {
    func descriptor(
        panel: SimulatorPanel,
        workspaceID: UUID,
        ownerConnectionID: UUID? = nil,
        currentConnectionID: UUID? = nil
    ) -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: panel.id.uuidString,
            workspaceID: workspaceID.uuidString,
            title: panel.displayTitle,
            selectedDeviceName: panel.selectedDeviceName,
            selectedDeviceState: panel.selectedDeviceState,
            status: statusName(panel.coordinator.status),
            isReady: panel.isFeatureReady && panel.coordinator.status == .streaming,
            supportsTouch: panel.coordinator.supports(.touch),
            supportsKeyboard: panel.coordinator.supports(.keyboard),
            supportsHardwareButtons: panel.coordinator.supports(.hardwareButtons),
            supportsRotation: panel.coordinator.supports(.rotation),
            ownerConnectionID: ownerConnectionID?.uuidString,
            // Ownership is personal to one connection. Shared payloads
            // (state-sync rows, workspace lists) pass no connection, so they
            // must say "unknown" (nil) rather than telling the owning phone
            // it lost control on every broadcast tick.
            isOwnedByCurrentConnection: currentConnectionID.map {
                ownerConnectionID != nil && ownerConnectionID == $0
            }
        )
    }

    func object<Value: Encodable>(_ value: Value) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func statusName(_ status: SimulatorSessionStatus) -> String {
        switch status {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .streaming:
            return "streaming"
        case .deviceUnavailable:
            return "device_unavailable"
        case .workerCrashed:
            return "worker_crashed"
        case .failed:
            return "failed"
        }
    }
}
