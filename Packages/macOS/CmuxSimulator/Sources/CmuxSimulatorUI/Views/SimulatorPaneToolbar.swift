import CmuxSimulator
import SwiftUI

struct SimulatorPaneToolbar: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        HStack(spacing: 8) {
            SimulatorDevicePicker(coordinator: coordinator)
            statusView
            Spacer(minLength: 8)
            controlButtons
            Divider().frame(height: 18)
            Button {
                coordinator.showsTools.toggle()
            } label: {
                resourceLabel(simulatorStrings.tools, systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .help(Text(simulatorStrings.tools))
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

}

private extension SimulatorPaneToolbar {
    @ViewBuilder var statusView: some View {
        switch coordinator.status {
        case .idle:
            resourceLabel(simulatorStrings.selectToStart, systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(simulatorStrings.connecting)
            }
            .foregroundStyle(.secondary)
        case .streaming:
            resourceLabel(simulatorStrings.streaming, systemImage: "circle.fill")
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
            resourceLabel(label, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button(action: coordinator.recover) {
                Text(simulatorStrings.reconnect)
            }
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
            resourceLabel(label, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(Text(label))
    }

    private func resourceLabel(
        _ label: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Label {
            Text(label)
        } icon: {
            Image(systemName: systemImage)
        }
    }

}
