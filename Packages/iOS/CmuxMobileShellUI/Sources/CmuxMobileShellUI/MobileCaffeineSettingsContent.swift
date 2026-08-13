#if os(iOS)
import SwiftUI

/// Value-only Settings section for the connected Mac's cmux-owned power state.
struct MobileCaffeineSettingsContent: View {
    let isEnabled: Bool?
    let isSupported: Bool
    let isBusy: Bool
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
                    ProgressView()
                        .controlSize(.small)
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
            } else if mutationFailed {
                Label(
                    L10n.string(
                        "mobile.settings.keepMacAwake.failed",
                        defaultValue: "Couldn't confirm the change on your Mac. The previous setting was restored."
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
