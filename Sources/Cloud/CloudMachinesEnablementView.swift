import AppKit
import CmuxCloud
import SwiftUI

/// First-use screen for the Cloud tab. It keeps the normal machines panel
/// untouched after ``CloudActivationCoordinator/State/enabled`` and gives
/// every setup outcome a recoverable action where one exists.
///
/// The screen paints the panel's opaque chrome color. The right sidebar's
/// backdrop is a behind-window material (or the translucent window fill when
/// backdrops are unified), which the dense machines tree mostly covers, but a
/// mostly empty onboarding card would otherwise let other windows show through.
struct CloudMachinesEnablementView: View {
    let coordinator: CloudActivationCoordinator
    let accountFlow: HostAccountFlow?
    let chromeBackgroundColor: NSColor

    private static let contentMaxWidth: CGFloat = 320
    private static let actionMaxWidth: CGFloat = 240

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    VStack(spacing: 6) {
                        Text(title)
                            .cmuxFont(size: 15, weight: .semibold)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle)
                            .cmuxFont(size: 12)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if showsBenefits {
                        CloudMachinesEnablementBenefits()
                    }
                    VStack(spacing: 8) {
                        actionContent
                    }
                    .frame(maxWidth: Self.actionMaxWidth)
                }
                .frame(maxWidth: Self.contentMaxWidth)
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: chromeBackgroundColor))
        .accessibilityIdentifier("CloudMachinesEnablement")
    }

    private var showsBenefits: Bool {
        switch coordinator.state {
        case .disabled, .cancelled: return true
        case .enabling, .enabled, .failed, .unavailable: return false
        }
    }

    @ViewBuilder
    private var hero: some View {
        if coordinator.state == .enabling {
            ProgressView()
                .controlSize(.regular)
                .frame(height: 44)
                .accessibilityLabel(title)
        } else {
            Image(systemName: heroSymbol)
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(heroTint)
                .frame(height: 44)
                .accessibilityHidden(true)
        }
    }

    private var heroSymbol: String {
        switch coordinator.state {
        case .disabled, .cancelled, .enabling, .enabled: return "cloud.fill"
        case .failed(.requiresPro): return "lock.circle"
        case .failed(.signInRequired): return "person.crop.circle.badge.plus"
        case .failed(.serviceUnavailable): return "exclamationmark.icloud"
        case .unavailable: return "icloud.slash"
        }
    }

    private var heroTint: Color {
        switch coordinator.state {
        case .disabled, .cancelled, .enabling, .enabled, .failed(.signInRequired): return .accentColor
        case .failed(.requiresPro): return .secondary
        case .failed(.serviceUnavailable): return .orange
        case .unavailable: return .secondary
        }
    }

    private var title: String {
        switch coordinator.state {
        case .disabled, .cancelled, .enabled:
            return String(localized: "cloud.enable.title", defaultValue: "Use Cloud Machines")
        case .enabling:
            return String(localized: "cloud.enable.loading.title", defaultValue: "Setting up Cloud Machines…")
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
                defaultValue: "Persistent Linux computers in the cloud that open as regular cmux workspaces."
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
            Button {
                coordinator.enable()
            } label: {
                Text(String(localized: "cloud.enable.action", defaultValue: "Enable Cloud"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("CloudMachinesEnableButton")
            Text(String(localized: "cloud.enable.planNote", defaultValue: "Requires a paid cmux plan."))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .enabling:
            actionButton(
                String(localized: "cloud.enable.cancel", defaultValue: "Cancel"),
                prominent: false,
                identifier: "CloudMachinesEnableCancelButton"
            ) {
                coordinator.cancel()
            }
        case .failed(.requiresPro):
            actionButton(
                String(localized: "cloud.enable.upgrade", defaultValue: "Upgrade to Pro"),
                prominent: true,
                identifier: "CloudMachinesEnableUpgradeButton"
            ) {
                ProUpgradePresenter.present(source: .machinesPanelRequiresPro)
            }
            retryButton(prominent: false)
        case .failed(.signInRequired):
            if let accountFlow {
                actionButton(
                    String(localized: "cloud.enable.signIn.action", defaultValue: "Sign In"),
                    prominent: true,
                    identifier: "CloudMachinesEnableSignInButton"
                ) {
                    accountFlow.startSignIn()
                }
            }
            retryButton(prominent: accountFlow == nil)
        case .failed(.serviceUnavailable):
            retryButton(prominent: true)
        case .enabled, .unavailable:
            EmptyView()
        }
    }

    private func retryButton(prominent: Bool) -> some View {
        actionButton(
            String(localized: "machines.unavailable.retry", defaultValue: "Retry"),
            prominent: prominent,
            identifier: "CloudMachinesEnableRetryButton"
        ) {
            coordinator.retry()
        }
    }

    @ViewBuilder
    private func actionButton(
        _ label: String,
        prominent: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Text(label).frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .accessibilityIdentifier(identifier)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// Three short reasons to enable Cloud, shown before setup starts. Each line
/// restates a shipped capability from the Cloud overview docs.
private struct CloudMachinesEnablementBenefits: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(
                symbol: "terminal",
                text: String(
                    localized: "cloud.enable.benefit.agents",
                    defaultValue: "Agents and terminals keep running after you close your laptop."
                )
            )
            row(
                symbol: "externaldrive",
                text: String(
                    localized: "cloud.enable.benefit.files",
                    defaultValue: "Files and installed tools stay on the machine between sessions."
                )
            )
            row(
                symbol: "laptopcomputer",
                text: String(
                    localized: "cloud.enable.benefit.reattach",
                    defaultValue: "Pick up where you left off from any Mac you sign in on."
                )
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .accessibilityElement(children: .contain)
    }

    private func row(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .cmuxFont(size: 13)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .cmuxFont(size: 12)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
