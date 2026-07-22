#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

@MainActor
struct MobileIrohPrivateNetworksSection: View {
    let configurations: [CmxIrohSettingsSnapshot.CustomPrivateNetwork]
    let availableMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac]
    let edit: (String) -> Void
    let add: () -> Void
    let setEnabled: (CmxIrohSettingsSnapshot.CustomPrivateNetwork, Bool) -> Void
    let requestRemoval: (String) -> Void

    var body: some View {
        Section {
            LabeledContent(
                L10n.string("mobile.iroh.private.lan", defaultValue: "Local Network Discovery"),
                value: L10n.string(
                    "mobile.iroh.private.automatic",
                    defaultValue: "Automatic"
                )
            )
            LabeledContent(
                L10n.string(
                    "mobile.iroh.private.tailscale",
                    defaultValue: "Tailscale Compatibility"
                ),
                value: L10n.string(
                    "mobile.iroh.private.tailscale.active",
                    defaultValue: "When Tailscale Is Active"
                )
            )

            ForEach(configurations) { configuration in
                HStack {
                    Toggle(isOn: Binding(
                        get: { configuration.isEnabled },
                        set: { setEnabled(configuration, $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(displayName(configuration))
                            Text(configuration.addresses.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Menu {
                        Button(L10n.string("mobile.common.edit", defaultValue: "Edit")) {
                            edit(configuration.macDeviceID)
                        }
                        Button(
                            L10n.string("mobile.common.remove", defaultValue: "Remove"),
                            role: .destructive
                        ) {
                            requestRemoval(configuration.macDeviceID)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(
                        L10n.string("mobile.common.actions", defaultValue: "Actions")
                    )
                }
            }

            Button(action: add) {
                Label(
                    L10n.string(
                        "mobile.iroh.private.custom.add",
                        defaultValue: "Add Private Addresses"
                    ),
                    systemImage: "plus"
                )
            }
            .disabled(unconfiguredMacs.isEmpty)
            .accessibilityIdentifier("MobileIrohAddCustomPrivatePath")
        } header: {
            Text(L10n.string("mobile.iroh.private", defaultValue: "Private Networks"))
        } footer: {
            Text(L10n.string(
                "mobile.iroh.private.footer",
                defaultValue: "Private addresses stay on this device and are fallback paths only. cmux pins the Mac's broker-authenticated Iroh EndpointID and current UDP port; an address never proves identity."
            ))
        }
    }

    var unconfiguredMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac] {
        let configuredIDs = Set(configurations.map(\.macDeviceID))
        return availableMacs.filter { !configuredIDs.contains($0.id) }
    }

    private func displayName(
        _ configuration: CmxIrohSettingsSnapshot.CustomPrivateNetwork
    ) -> String {
        let trimmed = configuration.macDisplayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty
            ? L10n.string("mobile.iroh.private.custom.unnamedMac", defaultValue: "Mac")
            : trimmed
    }
}
#endif
