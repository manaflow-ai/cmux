import CMUXMobileCore
import Foundation

struct SimulatorStreamPickerRow: Identifiable, Equatable {
    let id: String
    let label: String

    init(_ descriptor: MobileSimulatorPanelDescriptor) {
        id = descriptor.panelID
        let deviceName = descriptor.selectedDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let deviceName, !deviceName.isEmpty {
            label = deviceName
        } else {
            label = descriptor.title
        }
    }
}
