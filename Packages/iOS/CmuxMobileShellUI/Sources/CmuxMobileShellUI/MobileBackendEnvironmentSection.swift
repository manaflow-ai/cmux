#if os(iOS)
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

/// The Settings section switching this install between the production backend
/// (https://cmux.com + the production Stack project) and the staging backend
/// (the cmux-staging deployment + the development Stack project).
///
/// Switching is live: picking the other environment presents a confirmation
/// (it signs the user out), then the app root runs the switch transaction —
/// sign out of the old environment, quiesce the old graph, store the override,
/// rebuild the SwiftUI tree against the new backend. No relaunch is involved.
/// Tagged dev builds bake their backend at build time (`LocalConfig.plist` or
/// Info.plist values); for those the section states the pin and shows the
/// active environment instead of a picker that would not take effect.
struct MobileBackendEnvironmentSection: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.backendEnvironmentSwitchAction) private var switchAction

    let state: CMUXBackendEnvironmentSwitchState

    /// The selection → confirmation → action seam; flipping the picker only
    /// parks a target here, and only the dialog's confirm button invokes the
    /// switch action.
    @State private var confirmation = BackendEnvironmentSwitchConfirmation()

    init(state: CMUXBackendEnvironmentSwitchState) {
        self.state = state
    }

    var body: some View {
        if isVisible {
            Section {
                if state.isPinnedByBuild {
                    LabeledContent(
                        L10n.string(
                            "mobile.settings.backend.environment",
                            defaultValue: "Environment"
                        ),
                        value: environmentName(state.active)
                    )
                    .accessibilityIdentifier("MobileSettingsBackendPinnedRow")
                } else {
                    Picker(selection: environmentSelection) {
                        Text(environmentName(.production))
                            .tag(CMUXBackendEnvironmentOverride.production)
                        Text(environmentName(.staging))
                            .tag(CMUXBackendEnvironmentOverride.staging)
                    } label: {
                        Text(L10n.string(
                            "mobile.settings.backend.environment",
                            defaultValue: "Environment"
                        ))
                    }
                    .disabled(switchAction?.isRunning == true)
                    .accessibilityIdentifier("MobileSettingsBackendEnvironmentPicker")
                    .confirmationDialog(
                        confirmationTitle,
                        isPresented: confirmationPresented,
                        titleVisibility: .visible
                    ) {
                        Button(
                            L10n.string(
                                "mobile.settings.backend.confirmAction",
                                defaultValue: "Switch & Sign Out"
                            ),
                            role: .destructive
                        ) {
                            confirmation.confirm(using: switchAction)
                        }
                        // The system-provided Cancel button dismisses the
                        // dialog; the isPresented binding reverts the parked
                        // selection through `confirmation.cancel()`.
                    } message: {
                        Text(L10n.string(
                            "mobile.settings.backend.confirmMessage",
                            defaultValue: "Staging is a separate environment with separate accounts and data. Switching signs you out, and your Mac and iPhone must be on the same environment to pair."
                        ))
                    }
                }
            } header: {
                headerContent
            } footer: {
                Text(footerText)
            }
        }
    }

    /// The picker is for the team (verified @manaflow.ai) and DEBUG dogfood,
    /// but production must always be selectable: an actively-staging launch
    /// keeps the section visible even when the account gate says no, so nobody
    /// is stranded on staging. (Active always reflects the persisted override
    /// now — the live switch rebuilds the composition on commit — so there is
    /// no divergent pending override left to check.)
    private var isVisible: Bool {
        #if DEBUG
        return true
        #else
        return CMUXBackendEnvironmentSwitchGate.allows(authManager.currentUser)
            || state.active == .staging
        #endif
    }

    /// Flipping the picker parks the target behind the confirmation dialog;
    /// nothing is stored or switched until the user confirms.
    private var environmentSelection: Binding<CMUXBackendEnvironmentOverride> {
        Binding(
            get: { confirmation.selection(active: state.active) },
            set: { newValue in
                confirmation.select(newValue, active: state.active)
            }
        )
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { confirmation.pendingTarget != nil },
            set: { isPresented in
                if !isPresented {
                    confirmation.cancel()
                }
            }
        )
    }

    private var confirmationTitle: String {
        String(
            format: L10n.string(
                "mobile.settings.backend.confirmTitle",
                defaultValue: "Switch to %@?"
            ),
            environmentName(confirmation.pendingTarget ?? state.active)
        )
    }

    private var headerContent: some View {
        HStack(spacing: 6) {
            Text(L10n.string("mobile.settings.backend", defaultValue: "Backend"))
            if state.active == .staging {
                Text(L10n.string(
                    "mobile.settings.backend.stagingBadge",
                    defaultValue: "STAGING"
                ))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(.orange)
                .background(.orange.opacity(0.15), in: Capsule())
                .accessibilityIdentifier("MobileSettingsBackendStagingBadge")
            }
        }
    }

    private var footerText: String {
        if state.isPinnedByBuild {
            return L10n.string(
                "mobile.settings.backend.pinnedFooter",
                defaultValue: "This build's backend is pinned at build time. The environment choice takes effect only in TestFlight and App Store builds."
            )
        }
        return L10n.string(
            "mobile.settings.backend.footer",
            defaultValue: "Staging is a separate environment with separate accounts and data. Switching signs you out, and your Mac and iPhone must be on the same environment to pair."
        )
    }

    private func environmentName(_ environment: CMUXBackendEnvironmentOverride) -> String {
        switch environment {
        case .production:
            L10n.string("mobile.settings.backend.production", defaultValue: "Production")
        case .staging:
            L10n.string("mobile.settings.backend.staging", defaultValue: "Staging")
        }
    }
}
#endif
