import CmuxFoundation
import SwiftUI

/// Backend environment picker rendered below the identity card in the
/// Account section, only when ``AccountFlow/backendEnvironmentSwitcherVisible``.
///
/// The picker writes the host's persisted selection immediately
/// (``AccountFlow/selectBackendEnvironment(_:)``); the running process keeps
/// its launch-resolved environment, so when the pending selection diverges
/// from the active one the card shows a relaunch notice with a button that
/// asks the host to persist state and relaunch. Pinned builds (tagged dev
/// builds with baked `CMUX_*` launch environment) additionally get a note
/// that the picker only takes effect in unpinned builds.
@MainActor
struct BackendEnvironmentCard: View {
    let flow: AccountFlow

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
                Picker(
                    String(
                        localized: "settings.account.backendEnvironment.title",
                        defaultValue: "Backend Environment"
                    ),
                    selection: Binding(
                        get: { flow.pendingBackendEnvironment },
                        set: { flow.selectBackendEnvironment($0) }
                    )
                ) {
                    ForEach(AccountBackendEnvironment.allCases, id: \.self) { environment in
                        Text(environment.displayName).tag(environment)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
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
            if AccountBackendEnvironment.requiresRelaunch(
                pending: flow.pendingBackendEnvironment,
                active: flow.activeBackendEnvironment
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(
                        localized: "settings.account.backendEnvironment.relaunchNotice",
                        defaultValue: "cmux must relaunch to apply the new backend environment."
                    ))
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        flow.relaunchToApplyBackendEnvironment()
                    } label: {
                        Text(String(
                            localized: "settings.account.backendEnvironment.relaunch",
                            defaultValue: "Relaunch cmux"
                        ))
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
