#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

@MainActor
struct MobileIrohPrivateNetworksSection: View {
    let configurations: [CmxIrohSettingsSnapshot.CustomPrivateNetwork]
    let availableMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac]
    let probePresentation: (String, String) -> MobileIrohPrivatePathProbePresentation
    let isProbeInFlight: Bool
    let testAddress: (String, String) -> Void
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(
                            displayName(configuration),
                            isOn: Binding(
                                get: { configuration.isEnabled },
                                set: { setEnabled(configuration, $0) }
                            )
                        )
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
                    ForEach(configuration.addresses, id: \.self) { address in
                        HStack {
                            Text(address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            MobileIrohPrivatePathTestButton(
                                presentation: probePresentation(
                                    configuration.macDeviceID,
                                    address
                                ),
                                isAnotherProbeInFlight: isProbeInFlight
                            ) {
                                testAddress(configuration.macDeviceID, address)
                            }
                        }
                    }
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
                defaultValue: "Use your own VPN when relays are blocked, on restricted corporate networks, or when you prefer a private route. Keep the VPN active on both devices, then add one of the Mac's suggested addresses. Connections remain end-to-end encrypted and verify the Mac's Iroh identity."
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
