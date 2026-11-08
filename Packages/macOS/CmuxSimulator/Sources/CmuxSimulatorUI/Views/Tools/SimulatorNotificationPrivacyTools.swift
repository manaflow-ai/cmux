import SwiftUI

struct SimulatorNotificationPrivacyTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorNotificationPrivacyToolsContent(coordinator: coordinator)
            .id(coordinator.selectedDeviceID)
    }
}
