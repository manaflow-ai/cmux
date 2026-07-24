import SwiftUI

struct SimulatorToolsPanel: View {
    let coordinator: SimulatorPaneCoordinator
    let backgroundColor: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if coordinator.isPerformingControlAction {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(simulatorStrings.loading)
                            .foregroundStyle(.secondary)
                    }
                }
                if let failure = coordinator.controlFailure {
                    Label(simulatorStrings.failure(failure.code), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    DisclosureGroup {
                        Text(verbatim: failure.code)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } label: {
                        Text(simulatorStrings.technicalDetails)
                    }
                }
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
        .background(backgroundColor)
    }
}
