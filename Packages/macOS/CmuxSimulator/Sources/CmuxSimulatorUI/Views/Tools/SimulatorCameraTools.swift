import SwiftUI

struct SimulatorCameraTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorCameraToolsContent(coordinator: coordinator)
            .id(coordinator.selectedDeviceID)
    }
}
