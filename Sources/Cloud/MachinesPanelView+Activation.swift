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
        case .enabling:
            switch authState {
            case .checking:
                authCheckingState
            case .signedOut:
                authGate
            case .signedIn:
                authenticatedContent
            }
        case .disabled, .failed, .cancelled, .unavailable:
            switch authState {
            case .checking:
                authCheckingState
            case .signedOut:
                authGate
            case .signedIn:
                CloudMachinesEnablementView(
                    coordinator: activationCoordinator,
                    accountFlow: accountFlow,
                    billingPlanLoaded: billingPlanLoaded,
                    chromeBackgroundColor: chromeBackgroundColor
                )
            }
        }
    }

}
