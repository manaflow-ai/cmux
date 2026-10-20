import CmuxSimulator
import Foundation

struct SimulatorDevicePickerSnapshot: Equatable {
    let rows: [SimulatorDevicePickerRow]
    let selectedDeviceName: String
    let selectedDeviceSymbol: String
}

func simulatorDevicePickerSnapshot(
    devices: [SimulatorDevice],
    selectedDeviceID: String?,
    localizedState: (SimulatorDeviceState) -> String
) -> SimulatorDevicePickerSnapshot {
    let selectedDevice = devices.first(where: { $0.id == selectedDeviceID })
    return SimulatorDevicePickerSnapshot(
        rows: devices.map { device in
            SimulatorDevicePickerRow(
                id: device.id,
                label: simulatorDeviceRowLabel(
                    device,
                    among: devices,
                    localizedState: localizedState(device.state)
                ),
                isSelected: device.id == selectedDeviceID
            )
        },
        selectedDeviceName: selectedDevice?.name
            ?? String(localized: simulatorStrings.chooseDevice),
        selectedDeviceSymbol: selectedDevice?.family == .iPad ? "ipad" : "iphone"
    )
}

func simulatorDeviceRowLabel(
    _ device: SimulatorDevice,
    among devices: [SimulatorDevice],
    localizedState: String
) -> String {
    let duplicateName = devices.lazy.filter { $0.name == device.name }.prefix(2).count > 1
    if duplicateName {
        return "\(device.name) · \(device.runtimeName) · \(localizedState)"
    }
    return "\(device.name) · \(localizedState)"
}
