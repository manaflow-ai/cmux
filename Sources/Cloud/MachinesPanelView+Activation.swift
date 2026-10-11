import AppKit
import CmuxCloud
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
                CloudMachinesEnablementPanel(
                    coordinator: activationCoordinator,
                    accountFlow: accountFlow,
                    billingPlanLoaded: billingPlanLoaded,
                    chromeBackgroundColor: chromeBackgroundColor
                )
            }
        }
    }

}

/// Wires ``CloudMachinesEnablementView`` to the app: reads the coordinator and
/// account flow in its own body (so their changes redraw only this screen)
/// and routes each action to its service.
struct CloudMachinesEnablementPanel: View {
    let coordinator: CloudActivationCoordinator
    let accountFlow: HostAccountFlow?
    let billingPlanLoaded: Bool
    let chromeBackgroundColor: NSColor

    var body: some View {
        CloudMachinesEnablementView(
            phase: CloudMachinesEnablementPhase(coordinator.state),
            billingPlanLoaded: billingPlanLoaded,
            isPlanKnown: accountFlow?.hasLoadedBillingPlan == true,
            isProActive: accountFlow?.isProActive == true,
            unavailableMessage: CloudMachinesFeature.disabledMessage,
            chromeBackgroundColor: chromeBackgroundColor,
            onEnable: { coordinator.enable() },
            onCancel: { coordinator.cancel() },
            onRetry: { coordinator.retry() },
            onUpgrade: { ProUpgradePresenter.present(source: .machinesPanelRequiresPro) },
            onSignIn: signIn
        )
    }

    private var signIn: (() -> Void)? {
        guard let accountFlow else { return nil }
        return { accountFlow.startSignIn() }
    }
}

private extension CloudMachinesEnablementPhase {
    init(_ state: CloudActivationCoordinator.State) {
        switch state {
        case .disabled: self = .disabled
        case .enabling: self = .enabling
        case .enabled: self = .enabled
        case .failed(.requiresPro): self = .failed(.requiresPro)
        case .failed(.signInRequired): self = .failed(.signInRequired)
        case .failed(.serviceUnavailable): self = .failed(.serviceUnavailable)
        case .cancelled: self = .cancelled
        case .unavailable: self = .unavailable
        }
    }
}
