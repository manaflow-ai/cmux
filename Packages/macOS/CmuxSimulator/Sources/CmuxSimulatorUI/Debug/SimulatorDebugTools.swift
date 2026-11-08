#if DEBUG
import SwiftUI

struct SimulatorDebugTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        Button(role: .destructive) {
            coordinator.terminateRenderer()
        } label: {
            Text(simulatorStrings.terminateRenderer)
        }
    }
}
#endif
