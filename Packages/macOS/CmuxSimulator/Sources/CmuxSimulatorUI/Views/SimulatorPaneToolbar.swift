import CmuxSimulator
import SwiftUI

struct SimulatorPaneToolbar: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        HStack(spacing: 8) {
            SimulatorDevicePicker(
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

}

struct SimulatorDevicePickerSnapshot: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let isSelected: Bool
    }

    let rows: [Row]
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
            SimulatorDevicePickerSnapshot.Row(
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

private struct SimulatorDevicePickerActions {
    let select: (String) -> Void
    let refresh: () -> Void
}

// Keep the coordinator out of this subtree, but let SwiftUI own its identity.
// EquatableView recursively compared this closure-bearing view in AttributeGraph.
private struct SimulatorDevicePicker: View {
    let snapshot: SimulatorDevicePickerSnapshot
    let actions: SimulatorDevicePickerActions

    var body: some View {
        Menu {
            if snapshot.rows.isEmpty {
                Button(simulatorStrings.refresh, action: actions.refresh)
            } else {
                ForEach(snapshot.rows) { row in
                    Button {
                        actions.select(row.id)
                    } label: {
                        if row.isSelected {
                            Label(row.label, systemImage: "checkmark")
                        } else {
                            Text(row.label)
                        }
                    }
                }
                Divider()
                Button(simulatorStrings.refresh, action: actions.refresh)
            }
        } label: {
            Label(snapshot.selectedDeviceName, systemImage: snapshot.selectedDeviceSymbol)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private extension SimulatorPaneToolbar {
    @ViewBuilder var statusView: some View {
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

    var controlButtons: some View {
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

    func toolbarButton(
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
