import CmuxFoundation
import SwiftUI

/// Backend environment picker rendered below the identity card in the
/// Account section, only when ``AccountFlow/backendEnvironmentSwitcherVisible``.
///
/// The picker never writes through on selection: choosing a different
/// environment stages the choice (``BackendEnvironmentSwitchConfirmation``)
/// and presents a confirmation dialog whose action runs the host's live
/// switch (``AccountFlow/applyBackendEnvironment(_:)``); cancel reverts the
/// picker to the active environment. While the switch runs the picker row is
/// replaced by a progress row driven by
/// ``AccountFlow/backendEnvironmentSwitchPhase``, and when it finishes the
/// card shows a switched note until the flow's phase is reset. Pinned builds
/// (tagged dev builds with baked `CMUX_*` launch environment) show a pinned
/// note, keep the picker disabled, and never present the dialog.
@MainActor
struct BackendEnvironmentCard: View {
    let flow: AccountFlow
    @State private var confirmation = BackendEnvironmentSwitchConfirmation()

    init(flow: AccountFlow) {
        self.flow = flow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        localized: "settings.account.backendEnvironment.title",
                        defaultValue: "Backend Environment"
                    ))
                    .cmuxFont(size: 13, weight: .medium)
                    Text(String(
                        localized: "settings.account.backendEnvironment.footer",
                        defaultValue: "Staging is a separate environment with separate accounts and data. Switching signs you out, and your Mac and iPhone must be on the same environment to pair."
                    ))
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                switch flow.backendEnvironmentSwitchPhase {
                case .signingOut:
                    progressRow(label: String(
                        localized: "settings.account.backendEnvironment.progressSigningOut",
                        defaultValue: "Signing out…"
                    ))
                case .retargeting:
                    progressRow(label: String(
                        localized: "settings.account.backendEnvironment.progressSwitching",
                        defaultValue: "Switching backend…"
                    ))
                case .idle, .finished:
                    picker
                }
            }
            if flow.backendEnvironmentPinnedByLaunchEnvironment {
                Text(String(
                    localized: "settings.account.backendEnvironment.pinnedNote",
                    defaultValue: "This build's backend is pinned by its launch environment; the picker takes effect only in unpinned builds."
                ))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if flow.backendEnvironmentSwitchPhase == .finished {
                Text(String(
                    format: String(
                        localized: "settings.account.backendEnvironment.switched",
                        defaultValue: "Now on %@. Sign in to continue."
                    ),
                    flow.activeBackendEnvironment.displayName
                ))
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
                    defaultValue: "Switch & Sign Out"
                ))
            }
        } message: {
            Text(String(
                localized: "settings.account.backendEnvironment.confirmMessage",
                defaultValue: "Staging is a separate environment with separate accounts and data. Switching signs you out, and your Mac and iPhone must be on the same environment to pair."
            ))
        }
        .onDisappear {
            flow.resetBackendEnvironmentSwitchPhase()
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
                    confirmation.displayedSelection(active: flow.activeBackendEnvironment)
                },
                set: { newValue in
                    // A new selection settles the previous round's switched
                    // note before staging the next confirmation.
                    flow.resetBackendEnvironmentSwitchPhase()
                    confirmation.select(
                        newValue,
                        active: flow.activeBackendEnvironment,
                        pinned: flow.backendEnvironmentPinnedByLaunchEnvironment
                    )
                }
            )
        ) {
            ForEach(AccountBackendEnvironment.allCases, id: \.self) { environment in
                Text(environment.displayName).tag(environment)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(flow.backendEnvironmentPinnedByLaunchEnvironment || flow.isWorkingOnAuth)
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

    private var confirmationTitle: String {
        String(
            format: String(
                localized: "settings.account.backendEnvironment.confirmTitle",
                defaultValue: "Switch to %@?"
            ),
            confirmation.displayedSelection(active: flow.activeBackendEnvironment).displayName
        )
    }
}
