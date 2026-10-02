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
                VStack(spacing: 0) {
                    activationStatusBanner
                    authenticatedContent
                }
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

    private var activationStatusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.fill")
                .foregroundStyle(Color.accentColor)
            Text(String(localized: "cloud.enable.inlineLoading", defaultValue: "Connecting Cloud…"))
                .cmuxFont(size: 12, weight: .medium)
            Spacer(minLength: 8)
            Button(String(localized: "cloud.enable.cancel", defaultValue: "Cancel")) {
                activationCoordinator.cancel()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityIdentifier("CloudMachinesActivationStatus")
    }
}
