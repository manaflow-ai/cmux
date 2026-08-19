#if os(iOS)
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

/// The Settings section switching this install between the production backend
/// (https://cmux.com + the production Stack project) and the staging backend
/// (the cmux-staging deployment + the development Stack project).
///
/// The choice persists in `UserDefaults` and the composition root applies it
/// on the NEXT launch: iOS apps must not self-terminate, so after a change the
/// section shows a persistent "close and reopen" notice instead of exiting.
/// Tagged dev builds bake their backend at build time (`LocalConfig.plist` or
/// Info.plist values); for those the section states the pin and shows the
/// active environment instead of a picker that would not take effect.
struct MobileBackendEnvironmentSection: View {
    @Environment(AuthCoordinator.self) private var authManager

    let state: CMUXBackendEnvironmentSwitchState

    /// The picker's selection, seeded from the persisted override when the
    /// sheet is presented and written through on every change.
    @State private var pending: CMUXBackendEnvironmentOverride

    /// Whether a non-production override was persisted at presentation.
    /// Captured once so switching back to production never hides the section
    /// mid-interaction (the relaunch notice must stay readable).
    private let presentedWithNonProductionOverride: Bool

    init(state: CMUXBackendEnvironmentSwitchState) {
        self.state = state
        let pending = state.pending
        _pending = State(initialValue: pending)
        presentedWithNonProductionOverride = pending != .production
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
                    .accessibilityIdentifier("MobileSettingsBackendEnvironmentPicker")

                    if pending != state.active {
                        Label(
                            L10n.string(
                                "mobile.settings.backend.relaunchNotice",
                                defaultValue: "Close and reopen cmux to apply."
                            ),
                            systemImage: "arrow.clockwise.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("MobileSettingsBackendRelaunchNotice")
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
    /// but production must always be selectable: a persisted non-production
    /// override or an actively-staging launch keeps the section visible even
    /// when the account gate says no, so nobody is stranded on staging.
    private var isVisible: Bool {
        #if DEBUG
        return true
        #else
        return CMUXBackendEnvironmentSwitchGate.allows(authManager.currentUser)
            || presentedWithNonProductionOverride
            || state.active == .staging
        #endif
    }

    /// Writes through on selection so the choice survives however the app is
    /// next terminated (the relaunch is what applies it).
    private var environmentSelection: Binding<CMUXBackendEnvironmentOverride> {
        Binding(
            get: { pending },
            set: { newValue in
                guard newValue != pending else { return }
                pending = newValue
                state.setPending(newValue)
            }
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
