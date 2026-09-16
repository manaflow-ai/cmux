import CmuxSimulator
import SwiftUI

struct SimulatorPaneStateView: View {
    let coordinator: SimulatorPaneCoordinator
    let failure: SimulatorFailure?

    var body: some View {
        if let failure {
            ContentUnavailableView {
                SimulatorLocalizedLabel(simulatorStrings.failed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(simulatorStrings.failure(failure.code))
            } actions: {
                if failure.isRecoverable {
                    SimulatorLocalizedButton(simulatorStrings.reconnect, action: coordinator.recover)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if coordinator.isDiscoveringDevices || !coordinator.hasCompletedDeviceDiscovery {
            SimulatorPaneLoadingView(title: simulatorStrings.findingDevices, detail: nil)
        } else if coordinator.status == .connecting || coordinator.status == .streaming {
            SimulatorPaneLoadingView(
                title: simulatorStrings.connecting,
                detail: coordinator.selectedDevice?.name
            )
        } else if coordinator.devices.isEmpty {
            ContentUnavailableView {
                SimulatorLocalizedLabel(simulatorStrings.noDevices, systemImage: "iphone.slash")
            } description: {
                Text(simulatorStrings.noDevicesHelp)
            } actions: {
                SimulatorLocalizedButton(simulatorStrings.refresh) {
                    coordinator.scheduleControlAction("reload-devices") { _ = await $0.reloadDevices() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if coordinator.status == .workerCrashed || coordinator.status == .deviceUnavailable {
            ContentUnavailableView {
                SimulatorLocalizedLabel(
                    coordinator.status == .workerCrashed ? simulatorStrings.workerStopped : simulatorStrings.unavailable,
                    systemImage: "iphone.slash"
                )
            } actions: {
                SimulatorLocalizedButton(simulatorStrings.reconnect, action: coordinator.recover)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                SimulatorLocalizedLabel(simulatorStrings.selectToStart, systemImage: "iphone")
            } actions: {
                SimulatorDevicePicker(coordinator: coordinator)
                    .fixedSize()
            }
        }
    }
}
