import SwiftUI

struct SimulatorToolsPanel: View {
    let coordinator: SimulatorPaneCoordinator
    let backgroundColor: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(simulatorStrings.tools)
                    .font(.headline)
                Spacer()
                Button { coordinator.showsTools = false } label: {
                    SimulatorLocalizedLabel(simulatorStrings.closeTools, systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .padding(4)
                }
                .buttonStyle(.borderless)
                .help(Text(simulatorStrings.closeTools))
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SimulatorToolFeedbackView(
                        isWorking: coordinator.isPerformingControlAction,
                        failure: coordinator.controlFailure
                    )
                SimulatorDeviceTools(coordinator: coordinator)
                SimulatorTextInputTools(coordinator: coordinator)
                SimulatorApplicationTools(coordinator: coordinator)
                SimulatorURLMediaClipboardTools(coordinator: coordinator)
                SimulatorLocationTools(coordinator: coordinator)
                SimulatorNotificationPrivacyTools(coordinator: coordinator)
                SimulatorAppearanceTools(coordinator: coordinator)
                SimulatorCaptureTools(coordinator: coordinator)
                SimulatorLogTools(coordinator: coordinator)
                SimulatorCameraTools(coordinator: coordinator)
                SimulatorInspectionTools(coordinator: coordinator)
                SimulatorWebInspectorTools(coordinator: coordinator)
                SimulatorActivityTools(entries: coordinator.actionLog)
            }
                .padding(12)
            }
        }
        .background(backgroundColor)
    }
}
