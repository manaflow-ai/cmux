#if os(iOS)
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

/// The Settings section switching this install between the production backend
/// (https://cmux.com + the production Stack project) and the staging backend
/// (the cmux-staging deployment + the development Stack project).
///
/// Switching is live and PARKS the current environment's session: picking the
/// other environment presents a confirmation, then the app root runs the
/// switch transaction — detach (not sign out) the old session leaving its
/// token slot parked, quiesce the old graph, store the override, rebuild the
/// SwiftUI tree against the new backend, and establish a session on the
/// target (restoring its parked slot, or waiting for an inline sign-in on
/// staging). No relaunch is involved and no session is revoked.
///
/// Renders in one of three tiers
/// (``MobileBackendEnvironmentSectionVisibility``): the full picker for
/// gate-allowed users and DEBUG builds, a recovery-only "Switch Back to
/// Production" section for anyone else stranded on staging (routed through
/// the SAME confirmation machinery as the picker), or nothing. Tagged dev
/// builds bake their backend at build time (`LocalConfig.plist` or Info.plist
/// values); for those each tier states the pin instead of a control that
/// would not take effect.
struct MobileBackendEnvironmentSection: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.backendEnvironmentSwitchAction) private var switchAction

    let state: CMUXBackendEnvironmentSwitchState

    /// The selection → confirmation → action seam; flipping the picker (or
    /// tapping the recovery button) only parks a target here, and only the
    /// dialog's confirm button invokes the switch action.
    @State private var confirmation = BackendEnvironmentSwitchConfirmation()

    init(state: CMUXBackendEnvironmentSwitchState) {
        self.state = state
    }

    var body: some View {
        switch visibility {
        case .hidden:
            EmptyView()
        case .fullPicker:
            fullPickerSection
        case .stagingRecovery:
            stagingRecoverySection
        }
    }

    private var visibility: MobileBackendEnvironmentSectionVisibility {
        MobileBackendEnvironmentSectionVisibility.resolve(
            isGateAllowed: CMUXBackendEnvironmentSwitchGate.allows(authManager.currentUser),
            isDebugBuild: Self.isDebugBuild,
            isSwitchRunning: switchAction?.isRunning == true,
            active: state.active
        )
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // MARK: - Full picker tier

    private var fullPickerSection: some View {
        Section {
            if state.isPinnedByBuild {
                pinnedRow
            } else {
                switchConfirmationDialog(
                    attachedTo: Picker(selection: environmentSelection) {
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
                )
            }
        } header: {
            headerContent
        } footer: {
            Text(footerText)
        }
    }

    // MARK: - Staging recovery tier

    /// Recovery-only rendering for a non-gate user stranded on staging: the
    /// staging badge, an explanation, and a single switch-back button that
    /// routes through the SAME confirmation machinery as the picker
    /// (`select(.production)` → dialog → `confirm(using:)`). Pinned builds
    /// keep the pinned row instead of a button that could not take effect.
    private var stagingRecoverySection: some View {
        Section {
            if state.isPinnedByBuild {
                pinnedRow
            } else {
                Text(L10n.string(
                    "mobile.settings.backend.recoveryTitle",
                    defaultValue: "This device is on Staging"
                ))
                .font(.body.weight(.medium))
                .accessibilityIdentifier("MobileSettingsBackendRecoveryTitle")
                switchConfirmationDialog(
                    attachedTo: Button {
                        confirmation.select(.production, active: state.active)
                    } label: {
                        Text(L10n.string(
                            "mobile.settings.backend.recoveryAction",
                            defaultValue: "Switch Back to Production"
                        ))
                    }
                    .disabled(switchAction?.isRunning == true)
                    .accessibilityIdentifier("MobileSettingsBackendRecoverySwitchBackButton")
                )
            }
        } header: {
            headerContent
        } footer: {
            Text(state.isPinnedByBuild ? pinnedFooterText : recoveryExplanationText)
        }
    }

    // MARK: - Shared pieces

    private var pinnedRow: some View {
        LabeledContent(
            L10n.string(
                "mobile.settings.backend.environment",
                defaultValue: "Environment"
            ),
            value: environmentName(state.active)
        )
        .accessibilityIdentifier("MobileSettingsBackendPinnedRow")
    }

    /// The ONE confirmation dialog both tiers share, so the picker and the
    /// recovery button stay a single machinery (the tiers are exclusive, so
    /// only one dialog host exists at a time).
    private func switchConfirmationDialog(attachedTo content: some View) -> some View {
        content.confirmationDialog(
            confirmationTitle,
            isPresented: confirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string(
                    "mobile.settings.backend.confirmAction",
                    defaultValue: "Switch Environment"
                )
            ) {
                confirmation.confirm(using: switchAction)
            }
            // The system-provided Cancel button dismisses the dialog; the
            // isPresented binding reverts the parked selection through
            // `confirmation.cancel()`.
        } message: {
            Text(confirmationMessage)
        }
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

    /// Park semantics: the current environment's session stays on this
    /// iPhone, and sign-in to the target follows the switch.
    private var confirmationMessage: String {
        L10n.string(
            "mobile.settings.backend.confirmMessage",
            defaultValue: "Staging is a separate environment with separate accounts and data. Your current session is kept on this iPhone, and you'll be asked to sign in to the environment you switch to. Your Mac and iPhone must be on the same environment to pair."
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
            return pinnedFooterText
        }
        return L10n.string(
            "mobile.settings.backend.footer",
            defaultValue: "Staging is a separate environment with separate accounts and data. Each environment keeps its own session on this iPhone, and your Mac and iPhone must be on the same environment to pair."
        )
    }

    private var pinnedFooterText: String {
        L10n.string(
            "mobile.settings.backend.pinnedFooter",
            defaultValue: "This build's backend is pinned at build time. The environment choice takes effect only in TestFlight and App Store builds."
        )
    }

    private var recoveryExplanationText: String {
        L10n.string(
            "mobile.settings.backend.recoveryExplanation",
            defaultValue: "Staging is a separate cmux environment for testing, with separate accounts and data. Switch back to Production to use your normal account."
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
