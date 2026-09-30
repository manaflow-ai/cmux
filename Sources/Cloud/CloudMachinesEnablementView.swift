import CmuxCloud
import SwiftUI

/// First-use screen for the Cloud tab. It keeps the normal machines panel
/// untouched after ``CloudActivationCoordinator/State/enabled`` and gives
/// every setup outcome a recoverable action where one exists.
struct CloudMachinesEnablementView: View {
    let coordinator: CloudActivationCoordinator

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cloud")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .cmuxFont(size: 14, weight: .semibold)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            actionContent
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("CloudMachinesEnablement")
    }

    private var title: String {
        switch coordinator.state {
        case .disabled, .cancelled:
            return String(localized: "cloud.enable.title", defaultValue: "Use Cloud Machines")
        case .enabling:
            return String(localized: "cloud.enable.loading.title", defaultValue: "Setting up Cloud Machines…")
        case .enabled:
            return String(localized: "cloud.enable.title", defaultValue: "Use Cloud Machines")
        case .failed(.requiresPro):
            return String(localized: "cloud.enable.requiresPro.title", defaultValue: "Cloud Machines require cmux Pro")
        case .failed(.signInRequired):
            return String(localized: "cloud.enable.signIn.title", defaultValue: "Sign in to use Cloud Machines")
        case .failed(.serviceUnavailable):
            return String(localized: "cloud.enable.failed.title", defaultValue: "Cloud setup is temporarily unavailable")
        case .unavailable:
            return CloudMachinesFeature.disabledMessage
        }
    }

    private var subtitle: String {
        switch coordinator.state {
        case .disabled, .enabled:
            return String(
                localized: "cloud.enable.subtitle",
                defaultValue: "Create persistent cloud computers whose files stay available when they sleep."
            )
        case .enabling:
            return String(
                localized: "cloud.enable.loading.subtitle",
                defaultValue: "cmux is preparing the shared Cloud connection. This can take a moment."
            )
        case .cancelled:
            return String(
                localized: "cloud.enable.cancelled.subtitle",
                defaultValue: "Cloud was not enabled. You can start setup again whenever you are ready."
            )
        case .failed(.requiresPro):
            return String(
                localized: "cloud.enable.requiresPro.subtitle",
                defaultValue: "This account’s plan does not include Cloud machine access."
            )
        case .failed(.signInRequired):
            return String(
                localized: "cloud.enable.signIn.subtitle",
                defaultValue: "Sign in to your cmux account, then retry Cloud setup."
            )
        case .failed(.serviceUnavailable):
            return String(
                localized: "cloud.enable.failed.subtitle",
                defaultValue: "The Cloud service could not be reached. Check your connection and retry."
            )
        case .unavailable:
            return String(
                localized: "cloud.enable.unavailable.subtitle",
                defaultValue: "Cloud Machines are unavailable on this Mac right now."
            )
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        switch coordinator.state {
        case .disabled, .cancelled:
            Button(String(localized: "cloud.enable.action", defaultValue: "Enable Cloud")) {
                coordinator.enable()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("CloudMachinesEnableButton")
        case .enabling:
            ProgressView()
                .controlSize(.small)
            Button(String(localized: "cloud.enable.cancel", defaultValue: "Cancel")) {
                coordinator.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("CloudMachinesEnableCancelButton")
        case .failed(.requiresPro):
            Button(String(localized: "cloud.enable.upgrade", defaultValue: "Upgrade to Pro")) {
                ProUpgradePresenter.present(source: .machinesPanelRequiresPro)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("CloudMachinesEnableUpgradeButton")
            retryButton
        case .failed(.signInRequired), .failed(.serviceUnavailable):
            retryButton
        case .enabled, .unavailable:
            EmptyView()
        }
    }

    private var retryButton: some View {
        Button(String(localized: "machines.unavailable.retry", defaultValue: "Retry")) {
            coordinator.retry()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("CloudMachinesEnableRetryButton")
    }
}
