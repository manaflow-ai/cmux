#if DEBUG
import SwiftUI

struct SimulatorDebugTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        Button(simulatorStrings.terminateRenderer, role: .destructive) {
            coordinator.terminateRenderer()
        }
    }
}
#endif
