import SwiftUI

struct SimulatorPaneToolbar: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        ViewThatFits(in: .horizontal) {
            SimulatorPaneToolbarContent(coordinator: coordinator, compact: false)
            SimulatorPaneToolbarContent(coordinator: coordinator, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
