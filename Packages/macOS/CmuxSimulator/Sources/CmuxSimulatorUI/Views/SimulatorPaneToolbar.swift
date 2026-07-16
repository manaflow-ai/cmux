import CmuxSimulator
import SwiftUI

struct SimulatorPaneToolbar: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        HStack(spacing: 8) {
            devicePicker
            statusView
            Spacer(minLength: 8)
            controlButtons
            Divider().frame(height: 18)
            Button {
                coordinator.showsTools.toggle()
            } label: {
                Label(simulatorStrings.tools, systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .help(simulatorStrings.tools)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var devicePicker: some View {
        Menu {
            if coordinator.devices.isEmpty {
                Button(simulatorStrings.refresh) {
                    coordinator.scheduleControlAction("reload-devices") { _ = await $0.reloadDevices() }
                }
            } else {
                ForEach(coordinator.devices) { device in
                    let label = simulatorDeviceRowLabel(
                        device,
                        among: coordinator.devices,
                        localizedState: String(localized: simulatorStrings.deviceState(device.state))
                    )
                    Button {
                        coordinator.selectDevice(id: device.id)
                    } label: {
                        if device.id == coordinator.selectedDeviceID {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
                Divider()
                Button(simulatorStrings.refresh) {
                    coordinator.scheduleControlAction("reload-devices") { _ = await $0.reloadDevices() }
                }
            }
        } label: {
            Label(selectedDeviceName, systemImage: selectedDeviceSymbol)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var statusView: some View {
        switch coordinator.status {
        case .idle:
            Label(simulatorStrings.selectToStart, systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(simulatorStrings.connecting)
            }
            .foregroundStyle(.secondary)
        case .streaming:
            Label(simulatorStrings.streaming, systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .deviceUnavailable:
            recoveryStatus(simulatorStrings.unavailable)
        case .workerCrashed:
            recoveryStatus(simulatorStrings.workerStopped)
        case .failed:
            recoveryStatus(simulatorStrings.failed)
        }
    }

    private func recoveryStatus(_ label: LocalizedStringResource) -> some View {
        HStack(spacing: 5) {
            Label(label, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button(simulatorStrings.reconnect) { coordinator.recover() }
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 4) {
            toolbarButton(simulatorStrings.rotateLeft, symbol: "rotate.left", action: coordinator.rotateLeft)
                .disabled(!coordinator.supports(.rotation))
            toolbarButton(simulatorStrings.rotateRight, symbol: "rotate.right", action: coordinator.rotateRight)
                .disabled(!coordinator.supports(.rotation))
            toolbarButton(simulatorStrings.keyboard, symbol: "keyboard", action: coordinator.toggleSoftwareKeyboard)
                .disabled(!coordinator.supports(.keyboard))
            toolbarButton(simulatorStrings.home, symbol: "house", action: { coordinator.press(.home) })
                .disabled(!coordinator.supports(.hardwareButtons))
            toolbarButton(simulatorStrings.appSwitcher, symbol: "square.on.square", action: { coordinator.press(.appSwitcher) })
                .disabled(!coordinator.supports(.hardwareButtons))
            toolbarButton(simulatorStrings.lock, symbol: "lock", action: { coordinator.press(.lock) })
                .disabled(!coordinator.supports(.hardwareButtons))
        }
    }

    private func toolbarButton(
        _ label: LocalizedStringResource,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(label)
    }

    private var selectedDeviceName: String {
        coordinator.devices.first(where: { $0.id == coordinator.selectedDeviceID })?.name
            ?? String(localized: simulatorStrings.chooseDevice)
    }

    private var selectedDeviceSymbol: String {
        switch coordinator.devices.first(where: { $0.id == coordinator.selectedDeviceID })?.family {
        case .iPad: "ipad"
        default: "iphone"
        }
    }

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
