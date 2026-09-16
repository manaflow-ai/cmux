import CmuxSimulator
import SwiftUI

struct SimulatorPaneToolbarContent: View {
    @Bindable var coordinator: SimulatorPaneCoordinator
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                SimulatorDevicePicker(coordinator: coordinator)
                    .font(.body.weight(.medium))
                SimulatorPaneStatusView(
                    status: coordinator.status,
                    isDiscoveringDevices: coordinator.isDiscoveringDevices,
                    recover: coordinator.recover
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if compact {
                Menu {
                    SimulatorPaneControls(coordinator: coordinator)
                        .labelStyle(.titleAndIcon)
                } label: {
                    SimulatorLocalizedLabel(simulatorStrings.controls, systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Text(simulatorStrings.controls))
            } else {
                HStack(spacing: 4) {
                    SimulatorPaneControls(coordinator: coordinator)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .fixedSize()
            }

            Divider().frame(height: 22)
            Toggle(isOn: $coordinator.showsTools) {
                SimulatorLocalizedLabel(simulatorStrings.tools, systemImage: "sidebar.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .toggleStyle(.button)
            .help(Text(simulatorStrings.tools))
        }
    }
}
