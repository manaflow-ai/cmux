import SwiftUI

extension MachinesPanelView {
    @ViewBuilder
    var activationContent: some View {
        switch activationCoordinator.state {
        case .enabled:
            VStack(spacing: 0) {
                switch authState {
                case .checking:
                    authCheckingState
                case .signedOut:
                    authGate
                case .signedIn:
                    authenticatedContent
                }
            }
        case .disabled, .enabling, .failed, .cancelled, .unavailable:
            CloudMachinesEnablementView(
                coordinator: activationCoordinator,
                accountFlow: accountFlow,
                chromeBackgroundColor: chromeBackgroundColor
            )
        }
    }
}
