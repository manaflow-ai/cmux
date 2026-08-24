import CmuxFoundation
import SwiftUI

/// Backend environment card rendered below the identity card in the Account
/// section, in the tier chosen by ``AccountFlow/backendEnvironmentCardVisibility``:
/// the full environment picker for gate-allowed users and DEBUG builds, or a
/// recovery-only card for everyone else stranded off production.
///
/// The picker's option set follows the build lane
/// (``AccountBackendEnvironmentSelection/pickerOptions(for:)``): a
/// production-lane build keeps the two-position Production/Staging picker,
/// any other lane adds a "Build lane (…)" position that returns the build to
/// its own bake, with a footer explaining that bake. Neither variant writes
/// through on selection: a choice stages through
/// ``BackendEnvironmentSwitchConfirmation`` and presents a confirmation
/// dialog whose action runs the host's live switch
/// (``AccountFlow/applyBackendEnvironment(_:)``); cancel reverts. While the
/// switch runs the trailing control is replaced by a per-phase progress row
/// driven by ``AccountFlow/backendEnvironmentSwitchPhase``, and when it
/// finishes the card shows the outcome (switched, or reverted with the
/// reason) until the flow's phase is reset. The recovery variant offers the
/// switch-back button only for an EXPLICIT staging selection; a staging-LANE
/// build shows the lane explanation instead (its home is the bake, and
/// sign-out there stays plain).
@MainActor
struct BackendEnvironmentCard: View {
    /// Which tier of the card renders.
    enum Variant {
        /// The full environment picker.
        case fullPicker
        /// Recovery-only: explanation + (for explicit staging) a single
        /// switch-back button.
        case recovery
    }

    let flow: AccountFlow
    let variant: Variant
    @State private var confirmation = BackendEnvironmentSwitchConfirmation()

    init(flow: AccountFlow, variant: Variant = .fullPicker) {
        self.flow = flow
        self.variant = variant
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(
                            localized: "settings.account.backendEnvironment.title",
                            defaultValue: "Backend Environment"
                        ))
                        .cmuxFont(size: 13, weight: .medium)
                        if variant == .recovery, flow.activeBackendEnvironment == .staging {
                            StagingEnvironmentBadge()
                        }
                    }
                    Text(explanationText)
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailingControl
            }
            if variant == .fullPicker, flow.backendEnvironmentBuildLane != .production {
                Text(laneFooterText)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case let .finished(outcome) = flow.backendEnvironmentSwitchPhase {
                Text(outcomeText(outcome))
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation.isPresentingDialog },
                set: { presented in
                    // Any dismissal that did not go through the switch action
                    // (Cancel, Escape, click-away) reverts the staged choice.
                    if !presented { confirmation.cancel() }
                }
            ),
            titleVisibility: .visible
        ) {
            // Capture at content-build time: the staged selection is cleared
            // on dismissal, and the action must not depend on whether the
            // action or the dismissal binding runs first.
            let target = confirmation.pendingSelection
            Button {
                confirmation.cancel()
                if let target {
                    Task { await flow.applyBackendEnvironment(target) }
                }
            } label: {
                Text(String(
                    localized: "settings.account.backendEnvironment.confirmAction",
                    defaultValue: "Switch Environment"
                ))
            }
        } message: {
            Text(confirmationMessage)
        }
        .onDisappear {
            flow.resetBackendEnvironmentSwitchPhase()
        }
    }

    /// The picker option representing the ACTIVE selection. On a
    /// production-lane build the lane has no option of its own (the
    /// option-set rule keeps the two-position picker), so `.buildLane`
    /// normalizes to `.production` — the same option the host maps back to
    /// the lane on apply, making re-picking it a no-op.
    private var activeOption: AccountBackendEnvironmentSelection {
        let active = flow.activeBackendEnvironmentSelection
        if flow.backendEnvironmentBuildLane == .production, active == .buildLane {
            return .production
        }
        return active
    }

    // MARK: - Trailing control

    @ViewBuilder
    private var trailingControl: some View {
        switch flow.backendEnvironmentSwitchPhase {
        case .parking:
            progressRow(label: String(
                localized: "settings.account.backendEnvironment.progressParking",
                defaultValue: "Saving your session…"
            ))
        case .retargeting:
            progressRow(label: String(
                localized: "settings.account.backendEnvironment.progressSwitching",
                defaultValue: "Switching backend…"
            ))
        case .establishing:
            progressRow(label: String(
                localized: "settings.account.backendEnvironment.progressEstablishing",
                defaultValue: "Waiting for sign-in…"
            ))
        case .reverting:
            progressRow(label: String(
                localized: "settings.account.backendEnvironment.progressReverting",
                defaultValue: "Switching back…"
            ))
        case .idle, .finished:
            switch variant {
            case .fullPicker:
                picker
            case .recovery:
                // Only an EXPLICIT staging selection offers the switch-back
                // route; a staging-lane build's card is explanatory (the
                // lane is that build's home).
                if flow.activeBackendEnvironmentSelection == .staging {
                    switchBackButton
                }
            }
        }
    }

    private var picker: some View {
        Picker(
            String(
                localized: "settings.account.backendEnvironment.title",
                defaultValue: "Backend Environment"
            ),
            selection: Binding(
                get: {
                    confirmation.displayedSelection(active: activeOption)
                },
                set: { newValue in
                    // A new selection settles the previous round's outcome
                    // note before staging the next confirmation.
                    flow.resetBackendEnvironmentSwitchPhase()
                    confirmation.select(newValue, active: activeOption)
                }
            )
        ) {
            ForEach(
                AccountBackendEnvironmentSelection.pickerOptions(
                    for: flow.backendEnvironmentBuildLane
                ),
                id: \.self
            ) { option in
                Text(option.displayName(lane: flow.backendEnvironmentBuildLane)).tag(option)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(flow.isWorkingOnAuth)
    }

    private var switchBackButton: some View {
        Button {
            flow.resetBackendEnvironmentSwitchPhase()
            confirmation.requestSwitchBackToProduction(active: activeOption)
        } label: {
            Text(String(
                localized: "settings.account.backendEnvironment.recovery.switchBack",
                defaultValue: "Switch Back to Production"
            ))
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(flow.isWorkingOnAuth)
    }

    private func progressRow(label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Copy

    private var explanationText: String {
        switch variant {
        case .fullPicker:
            return String(
                localized: "settings.account.backendEnvironment.footer",
                defaultValue: "Staging is a separate environment with separate accounts and data. Each environment keeps its own session on this Mac, and your Mac and iPhone must be on the same environment to pair."
            )
        case .recovery:
            // A staging-lane build (no explicit choice) explains the bake;
            // the switch-back copy is reserved for explicit staging.
            if flow.activeBackendEnvironmentSelection == .buildLane {
                return laneFooterText
            }
            return String(
                localized: "settings.account.backendEnvironment.recovery.explanation",
                defaultValue: "This cmux is using the Staging environment, a separate deployment with separate accounts and data. Switch back to Production to use your normal account."
            )
        }
    }

    private var laneFooterText: String {
        String(
            format: String(
                localized: "settings.account.backendEnvironment.laneFooter",
                defaultValue: "This build's own lane is %@, baked in at build time. The build lane option returns to it."
            ),
            flow.backendEnvironmentBuildLane.label
        )
    }

    private func outcomeText(_ outcome: AccountBackendEnvironmentSwitchOutcome) -> String {
        // After a finished run the flow has rebound, so the ACTIVE selection
        // names where the device ended up (target on switched, previous on
        // reverted).
        if case .switched = outcome, flow.activeBackendEnvironmentSelection == .buildLane {
            return String(
                format: String(
                    localized: "settings.account.backendEnvironment.switchedLane",
                    defaultValue: "Now on the build lane (%@)."
                ),
                flow.backendEnvironmentBuildLane.label
            )
        }
        let environmentName = flow.activeBackendEnvironment.displayName
        switch outcome {
        case .switched:
            return String(
                format: String(
                    localized: "settings.account.backendEnvironment.switched",
                    defaultValue: "Now on %@."
                ),
                environmentName
            )
        case .reverted(.signInCancelled):
            return String(
                format: String(
                    localized: "settings.account.backendEnvironment.revertedSignInCancelled",
                    defaultValue: "Sign-in was cancelled, so you're back on %@."
                ),
                environmentName
            )
        case .reverted(.signInFailed):
            return String(
                format: String(
                    localized: "settings.account.backendEnvironment.revertedSignInFailed",
                    defaultValue: "Sign-in didn't complete, so you're back on %@."
                ),
                environmentName
            )
        case .reverted(.notEligible):
            return String(
                format: String(
                    localized: "settings.account.backendEnvironment.revertedNotEligible",
                    defaultValue: "That account can't use Staging, so you're back on %@."
                ),
                environmentName
            )
        }
    }

    private var displayedTarget: AccountBackendEnvironmentSelection {
        confirmation.displayedSelection(active: activeOption)
    }

    private var confirmationTitle: String {
        if displayedTarget == .buildLane {
            return String(
                format: String(
                    localized: "settings.account.backendEnvironment.confirmTitleLane",
                    defaultValue: "Switch back to the build lane (%@)?"
                ),
                flow.backendEnvironmentBuildLane.label
            )
        }
        return String(
            format: String(
                localized: "settings.account.backendEnvironment.confirmTitle",
                defaultValue: "Switch to %@?"
            ),
            displayedTarget
                .resolvedEnvironment(lane: flow.backendEnvironmentBuildLane)
                .displayName
        )
    }

    private var confirmationMessage: String {
        if displayedTarget == .buildLane {
            return String(
                format: String(
                    localized: "settings.account.backendEnvironment.confirmMessageLane",
                    defaultValue: "Your %1$@ session is kept on this Mac, and cmux returns to what this build is baked to (%2$@). Each environment has separate accounts and data."
                ),
                flow.activeBackendEnvironment.displayName,
                flow.backendEnvironmentBuildLane.label
            )
        }
        return String(
            format: String(
                localized: "settings.account.backendEnvironment.confirmMessage",
                defaultValue: "Your %1$@ session is kept on this Mac, and you'll be asked to sign in to %2$@. Each environment has separate accounts and data, and your Mac and iPhone must be on the same environment to pair."
            ),
            flow.activeBackendEnvironment.displayName,
            displayedTarget
                .resolvedEnvironment(lane: flow.backendEnvironmentBuildLane)
                .displayName
        )
    }
}
