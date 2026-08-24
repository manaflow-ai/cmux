#if os(iOS)
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

/// The Settings section switching this install between the production backend
/// (https://cmux.com + the production Stack project), the staging backend
/// (the cmux-staging deployment + the development Stack project), and — on a
/// non-production-lane build — the build's own lane (its bake).
///
/// Switching is live and PARKS the current environment's session: picking
/// another option presents a confirmation, then the app root runs the switch
/// transaction — detach (not sign out) the old session leaving its token slot
/// parked, quiesce the old graph, store the selection (an explicit choice
/// persists its raw value; the lane clears the key), rebuild the SwiftUI tree
/// against the new backend, and establish a session on the target (restoring
/// its parked slot, or waiting for an inline sign-in on explicit staging). No
/// relaunch is involved and no session is revoked.
///
/// An explicit choice is a WHOLESALE override beating every build-time bake,
/// so there is no pinned/refusal state left: the picker always works. The
/// option set follows the build lane
/// (``MobileBackendEnvironmentSelection/pickerOptions(for:)``): a
/// production-lane build keeps the two-position Production/Staging picker
/// ("Production" maps to the lane in the app root), any other lane adds a
/// "Build lane (…)" position, with a footer explaining the bake.
///
/// Renders in one of three tiers
/// (``MobileBackendEnvironmentSectionVisibility``): the full picker for
/// gate-allowed users and DEBUG builds, a recovery-only section for anyone
/// else whose selection resolves staging (a switch-back button ONLY for
/// explicit staging, routed through the SAME confirmation machinery as the
/// picker; a staging-LANE build shows the lane explanation instead), or
/// nothing.
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
            selection: state.selection
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
            switchConfirmationDialog(
                attachedTo: Picker(selection: environmentSelection) {
                    ForEach(
                        MobileBackendEnvironmentSelection.pickerOptions(for: state.buildLane),
                        id: \.self
                    ) { option in
                        Text(optionName(option)).tag(option)
                    }
                } label: {
                    Text(L10n.string(
                        "mobile.settings.backend.environment",
                        defaultValue: "Environment"
                    ))
                }
                .disabled(switchAction?.isRunning == true)
                .accessibilityIdentifier("MobileSettingsBackendEnvironmentPicker")
            )
        } header: {
            headerContent
        } footer: {
            Text(footerText)
        }
    }

    // MARK: - Staging recovery tier

    /// Recovery-only rendering for a non-gate user whose selection resolves
    /// staging: the staging badge, an explanation, and — ONLY for an EXPLICIT
    /// staging selection — a single switch-back button that routes through
    /// the SAME confirmation machinery as the picker (`select(.production)` →
    /// dialog → `confirm(using:)`). A staging-LANE build's section is
    /// explanatory instead: the lane is that build's home, and there is no
    /// explicit choice to clear.
    private var stagingRecoverySection: some View {
        Section {
            Text(L10n.string(
                "mobile.settings.backend.recoveryTitle",
                defaultValue: "This device is on Staging"
            ))
            .font(.body.weight(.medium))
            .accessibilityIdentifier("MobileSettingsBackendRecoveryTitle")
            if state.selection == .explicit(.staging) {
                switchConfirmationDialog(
                    attachedTo: Button {
                        confirmation.select(.production, active: activeOption)
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
            Text(state.selection == .explicit(.staging)
                ? recoveryExplanationText
                : laneFooterText)
        }
    }

    // MARK: - Shared pieces

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

    /// The picker option representing the ACTIVE selection. On a
    /// production-lane build the lane has no option of its own (the
    /// option-set rule keeps the two-position picker), so a lane selection
    /// normalizes to `.production` — the same option the app root maps back
    /// to the lane on apply, making re-picking it a no-op.
    private var activeOption: MobileBackendEnvironmentSelection {
        switch state.selection {
        case .lane:
            state.buildLane == .production ? .production : .buildLane
        case .explicit(.production):
            .production
        case .explicit(.staging):
            .staging
        }
    }

    /// Flipping the picker parks the target behind the confirmation dialog;
    /// nothing is stored or switched until the user confirms.
    private var environmentSelection: Binding<MobileBackendEnvironmentSelection> {
        Binding(
            get: { confirmation.selection(active: activeOption) },
            set: { newValue in
                confirmation.select(newValue, active: activeOption)
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
        let target = confirmation.pendingTarget ?? activeOption
        if target == .buildLane {
            return String(
                format: L10n.string(
                    "mobile.settings.backend.confirmTitleLane",
                    defaultValue: "Switch back to the build lane (%@)?"
                ),
                buildLaneLabel
            )
        }
        return String(
            format: L10n.string(
                "mobile.settings.backend.confirmTitle",
                defaultValue: "Switch to %@?"
            ),
            environmentName(target.resolvedEnvironment(lane: state.buildLane))
        )
    }

    /// Park semantics: the current environment's session stays on this
    /// iPhone. A lane target names the bake it returns to; an explicit
    /// target says sign-in to it follows the switch.
    private var confirmationMessage: String {
        if (confirmation.pendingTarget ?? activeOption) == .buildLane {
            return String(
                format: L10n.string(
                    "mobile.settings.backend.confirmMessageLane",
                    defaultValue: "Your %1$@ session is kept on this iPhone, and cmux returns to what this build is baked to (%2$@). Each environment has separate accounts and data."
                ),
                environmentName(state.selection.resolvedEnvironment),
                buildLaneLabel
            )
        }
        return L10n.string(
            "mobile.settings.backend.confirmMessage",
            defaultValue: "Staging is a separate environment with separate accounts and data. Your current session is kept on this iPhone, and you'll be asked to sign in to the environment you switch to. Your Mac and iPhone must be on the same environment to pair."
        )
    }

    private var headerContent: some View {
        HStack(spacing: 6) {
            Text(L10n.string("mobile.settings.backend", defaultValue: "Backend"))
            if state.selection.resolvedEnvironment == .staging {
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
        let footer = L10n.string(
            "mobile.settings.backend.footer",
            defaultValue: "Staging is a separate environment with separate accounts and data. Each environment keeps its own session on this iPhone, and your Mac and iPhone must be on the same environment to pair."
        )
        guard state.buildLane != .production else { return footer }
        return "\(footer)\n\n\(laneFooterText)"
    }

    /// Explains the bake behind the "Build lane (…)" option (and stands in
    /// for the recovery explanation on a staging-LANE build, whose home is
    /// the bake).
    private var laneFooterText: String {
        String(
            format: L10n.string(
                "mobile.settings.backend.laneFooter",
                defaultValue: "This build's own lane is %@, baked in at build time. The build lane option returns to it."
            ),
            buildLaneLabel
        )
    }

    private var recoveryExplanationText: String {
        L10n.string(
            "mobile.settings.backend.recoveryExplanation",
            defaultValue: "Staging is a separate cmux environment for testing, with separate accounts and data. Switch back to Production to use your normal account."
        )
    }

    private func optionName(_ option: MobileBackendEnvironmentSelection) -> String {
        switch option {
        case .buildLane:
            String(
                format: L10n.string(
                    "mobile.settings.backend.buildLaneOption",
                    defaultValue: "Build lane (%@)"
                ),
                buildLaneLabel
            )
        case .production:
            environmentName(.production)
        case .staging:
            environmentName(.staging)
        }
    }

    /// The human name substituted into "Build lane (%@)" strings: the lane's
    /// environment name, or a custom lane's baked host[:port] label.
    private var buildLaneLabel: String {
        switch state.buildLane {
        case .production:
            environmentName(.production)
        case .staging:
            environmentName(.staging)
        case .custom(let label):
            label
        }
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
