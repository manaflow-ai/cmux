import SwiftUI

struct SimulatorDevicePicker: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorDevicePickerMenu(
            snapshot: simulatorDevicePickerSnapshot(
                devices: coordinator.devices,
                selectedDeviceID: coordinator.selectedDeviceID,
                localizedState: {
                    String(localized: simulatorStrings.deviceState($0))
                }
            ),
            actions: SimulatorDevicePickerActions(
                select: { coordinator.selectDevice(id: $0) },
                refresh: {
                    coordinator.scheduleControlAction("reload-devices") {
                        _ = await $0.reloadDevices()
                    }
                }
            )
        )
    }
}
