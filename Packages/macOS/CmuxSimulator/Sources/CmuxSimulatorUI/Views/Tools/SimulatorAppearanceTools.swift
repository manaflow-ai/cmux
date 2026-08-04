import SwiftUI

struct SimulatorAppearanceTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorAppearanceToolsContent(coordinator: coordinator)
            .id(coordinator.selectedDeviceID)
    }
}
