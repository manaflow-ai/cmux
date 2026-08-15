#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Value-only Settings section for the connected Mac's cmux-owned power state.
struct MobileCaffeineSettingsContent: View {
    let isEnabled: Bool?
    let isSupported: Bool
    let isBusy: Bool
    let statusLoadFailed: Bool
    let onRetryStatus: () -> Void
    let onSet: (Bool) async -> Bool

    @State private var mutationFailed = false

    var body: some View {
        Section {
            HStack {
                Label(
                    L10n.string(
                        "mobile.settings.keepMacAwake",
                        defaultValue: "Keep Mac Awake"
                    ),
                    systemImage: "cup.and.saucer.fill"
                )
                Spacer()
                if isSupported, isEnabled == nil {
                    if statusLoadFailed || mutationFailed {
                        Button(
                            L10n.string("mobile.common.retry", defaultValue: "Retry"),
                            action: {
                                mutationFailed = false
                                onRetryStatus()
                            }
                        )
                        .accessibilityIdentifier("MobileSettingsKeepMacAwakeRetry")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    Toggle(
                        L10n.string(
                            "mobile.settings.keepMacAwake",
                            defaultValue: "Keep Mac Awake"
                        ),
                        isOn: Binding(
                            get: { isEnabled ?? false },
                            set: { enabled in
                                Task { @MainActor in
                                    mutationFailed = !(await onSet(enabled))
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .disabled(!isSupported || isEnabled == nil || isBusy)
                    .accessibilityIdentifier("MobileSettingsKeepMacAwakeToggle")
                }
            }

            if !isSupported {
                Text(L10n.string(
                    "mobile.settings.keepMacAwake.updateRequired",
                    defaultValue: "Update cmux on this Mac to control Keep Mac Awake from iPhone."
                ))
                .foregroundStyle(.secondary)
            } else if statusLoadFailed {
                Label(
                    L10n.string(
                        "mobile.settings.keepMacAwake.loadFailed",
                        defaultValue: "Couldn't load the Mac's Keep Mac Awake status. Check the connection and retry."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("MobileSettingsKeepMacAwakeLoadError")
            } else if mutationFailed {
                Label(
                    L10n.string(
                        "mobile.settings.keepMacAwake.failed",
                        defaultValue: "Couldn't confirm the change on your Mac. Check the connection and retry."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("MobileSettingsKeepMacAwakeError")
            }
        } header: {
            Text(L10n.string("mobile.settings.macPower", defaultValue: "Mac Power"))
        } footer: {
            Text(L10n.string(
                "mobile.settings.keepMacAwake.footer",
                defaultValue: "Prevents this Mac from sleeping while cmux is open. Its display can still turn off."
            ))
        }
    }
}
#endif
