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
    // CoreSimulator can retain many devices across installed runtimes. Count
    // names once so rebuilding the picker stays linear instead of scanning the
    // complete device list again for every row on the main thread.
    let nameCounts = devices.reduce(into: [String: Int]()) { counts, device in
        counts[device.name, default: 0] += 1
    }
    return SimulatorDevicePickerSnapshot(
        rows: devices.map { device in
            SimulatorDevicePickerRow(
                id: device.id,
                label: simulatorDeviceRowLabel(
                    device,
                    hasDuplicateName: nameCounts[device.name, default: 0] > 1,
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
    simulatorDeviceRowLabel(
        device,
        hasDuplicateName: devices.lazy.filter { $0.name == device.name }.prefix(2).count > 1,
        localizedState: localizedState
    )
}

private func simulatorDeviceRowLabel(
    _ device: SimulatorDevice,
    hasDuplicateName: Bool,
    localizedState: String
) -> String {
    if hasDuplicateName {
        return "\(device.name) · \(device.runtimeName) · \(localizedState)"
    }
    return "\(device.name) · \(localizedState)"
}
