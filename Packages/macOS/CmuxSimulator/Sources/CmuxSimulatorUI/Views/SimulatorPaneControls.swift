import CmuxSimulator
import SwiftUI

/// The same actions back both the wide toolbar and its compact overflow menu.
struct SimulatorPaneControls: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        control(simulatorStrings.rotateLeft, symbol: "rotate.left", action: coordinator.rotateLeft)
            .disabled(!coordinator.supports(.rotation))
        control(simulatorStrings.rotateRight, symbol: "rotate.right", action: coordinator.rotateRight)
            .disabled(!coordinator.supports(.rotation))
        control(simulatorStrings.keyboard, symbol: "keyboard", action: coordinator.toggleSoftwareKeyboard)
            .disabled(!coordinator.supports(.keyboard))
        control(simulatorStrings.home, symbol: "house", action: { coordinator.press(.home) })
            .disabled(!coordinator.supports(.hardwareButtons))
        control(simulatorStrings.appSwitcher, symbol: "square.on.square", action: { coordinator.press(.appSwitcher) })
            .disabled(!coordinator.supports(.hardwareButtons))
        control(simulatorStrings.lock, symbol: "lock", action: { coordinator.press(.lock) })
            .disabled(!coordinator.supports(.hardwareButtons))
    }

    private func control(
        _ title: LocalizedStringResource,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SimulatorLocalizedLabel(title, systemImage: symbol)
                .padding(5)
        }
        .help(Text(title))
    }
}
