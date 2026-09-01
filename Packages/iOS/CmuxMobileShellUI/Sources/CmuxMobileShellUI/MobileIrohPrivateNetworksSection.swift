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

    @State private var showsAdvancedPaths = false

    var body: some View {
        Section {
            LabeledContent(
                L10n.string("mobile.iroh.private.lan", defaultValue: "Local Network Discovery"),
                value: L10n.string(
                    "mobile.iroh.private.automatic",
                    defaultValue: "Automatic"
                )
            )

            if availableMacs.contains(where: { !$0.supportsPrivatePaths }) {
                Label(
                    L10n.string(
                        "mobile.iroh.private.macUpdateRequired",
                        defaultValue: "Update cmux on the Mac before configuring private addresses"
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
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

            DisclosureGroup(isExpanded: $showsAdvancedPaths) {
                ForEach(configurations) { configuration in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { configuration.isEnabled },
                            set: { setEnabled(configuration, $0) }
                        )) {
                            VStack(alignment: .leading) {
                                Text(MacAppInstanceDisplayFormatter().displayName(
                                    configuration.macDisplayName,
                                    instanceTag: configuration.instanceTag
                                ))
                                Text(configuration.addresses.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Menu {
                            Button(L10n.string("mobile.common.edit", defaultValue: "Edit")) {
                                edit(configuration.id)
                            }
                            Button(
                                L10n.string("mobile.common.remove", defaultValue: "Remove"),
                                role: .destructive
                            ) {
                                requestRemoval(configuration.id)
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
                // With all Macs configured the action appends to an existing
                // configuration, so it only disables when no Mac is known.
                .disabled(unconfiguredMacs.isEmpty && configurations.isEmpty)
                .accessibilityIdentifier("MobileIrohAddCustomPrivatePath")
            } label: {
                Text(L10n.string(
                    "mobile.iroh.private.advanced",
                    defaultValue: "Advanced Private Addresses"
                ))
            }
            .accessibilityIdentifier("MobileIrohAdvancedPrivatePaths")
        } header: {
            Text(L10n.string("mobile.iroh.private", defaultValue: "Private Networks"))
        } footer: {
            Text(L10n.string(
                "mobile.iroh.private.footer",
                defaultValue: "Most people do not need private addresses. Suggested VPN addresses are not available until a newer Mac build can provide them after authentication. Update cmux on the Mac first, then use a private address only when IT provides a route that automatic LAN, VPN, and relay discovery cannot find."
            ))
        }
    }

    var unconfiguredMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac] {
        let configuredIDs = Set(configurations.map(\.id))
        return availableMacs.filter { !configuredIDs.contains($0.id) }
    }
}
#endif
