#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

@MainActor
struct MobileIrohSettingsView: View {
    @State private var model: MobileIrohSettingsModel
    @State private var showsCustomEditor = false
    @State private var editedCustomRelayID: String?
    @State private var pendingCustomRemovalID: String?

    init(controller: any CmxIrohSettingsControlling) {
        _model = State(initialValue: MobileIrohSettingsModel(controller: controller))
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    L10n.string("mobile.iroh.preference", defaultValue: "Relay Preference"),
                    selection: preferenceBinding
                ) {
                    Text(L10n.string("mobile.iroh.preference.automatic", defaultValue: "Automatic"))
                        .tag(PreferenceChoice.automatic)
                    Text(L10n.string("mobile.iroh.preference.managed", defaultValue: "Selected cmux Relays"))
                        .tag(PreferenceChoice.managed)
                    Text(L10n.string("mobile.iroh.preference.custom", defaultValue: "Custom Relays"))
                        .tag(PreferenceChoice.custom)
                }
                .accessibilityIdentifier("MobileIrohRelayPreference")

                if preferenceChoice == .managed {
                    ForEach(model.snapshot.managedRelays) { relay in
                        Toggle(isOn: managedRelayBinding(relay.id)) {
                            VStack(alignment: .leading) {
                                Text(relay.region)
                                Text(relay.provider).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("MobileIrohManagedRelay-\(relay.id)")
                    }
                }
            } header: {
                Text(L10n.string("mobile.iroh.relays", defaultValue: "Iroh Relays"))
            } footer: {
                Text(L10n.string(
                    "mobile.iroh.relays.footer",
                    defaultValue: "Direct peer-to-peer stays enabled. cmux verifies a signed relay catalog, so fleet changes do not require an app update."
                ))
            }

            Section {
                ForEach(model.snapshot.customRelays) { relay in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(relay.displayName)
                            Text(customRelaySubtitle(relay)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button(L10n.string("mobile.iroh.test", defaultValue: "Test Connection")) {
                                model.testCustomRelay(id: relay.id)
                            }
                            Button(L10n.string("mobile.common.edit", defaultValue: "Edit")) {
                                editedCustomRelayID = relay.id
                                showsCustomEditor = true
                            }
                            Button(L10n.string("mobile.common.remove", defaultValue: "Remove"), role: .destructive) {
                                pendingCustomRemovalID = relay.id
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(L10n.string("mobile.common.actions", defaultValue: "Actions"))
                    }
                }
                Button {
                    editedCustomRelayID = nil
                    showsCustomEditor = true
                } label: {
                    Label(L10n.string("mobile.iroh.custom.add", defaultValue: "Add Custom Relay"), systemImage: "plus")
                }
                .accessibilityIdentifier("MobileIrohAddCustomRelay")
            } header: {
                Text(L10n.string("mobile.iroh.custom", defaultValue: "Custom Relays"))
            } footer: {
                Text(L10n.string(
                    "mobile.iroh.custom.footer",
                    defaultValue: "Addresses sync with your account. Provider secrets stay in this device's Keychain. A missing secret never enables another relay provider."
                ))
            }

            Section {
                LabeledContent(
                    L10n.string("mobile.iroh.private.iroh", defaultValue: "Iroh Private Paths"),
                    value: L10n.string("mobile.iroh.private.automatic", defaultValue: "Automatic")
                )
                LabeledContent(
                    L10n.string("mobile.iroh.private.tailscale", defaultValue: "Tailscale Compatibility"),
                    value: L10n.string("mobile.iroh.private.automatic", defaultValue: "Automatic")
                )
            } header: {
                Text(L10n.string("mobile.iroh.private", defaultValue: "Private Networks"))
            } footer: {
                Text(L10n.string(
                    "mobile.iroh.private.footer",
                    defaultValue: "Iroh discovers LAN and VPN paths after authenticating the Mac. Custom raw TCP routes are not accepted because they cannot prove the remote Mac."
                ))
            }

            Section {
                LabeledContent(
                    L10n.string("mobile.iroh.status", defaultValue: "Connection"),
                    value: runtimeStatusText
                )
                LabeledContent(
                    L10n.string("mobile.iroh.policy", defaultValue: "Relay Policy"),
                    value: policyStatusText
                )
                if !model.snapshot.staleRelayIDs.isEmpty || model.snapshot.failureDescription != nil {
                    Label(
                        L10n.string(
                            "mobile.iroh.attention",
                            defaultValue: "Your relay preference needs attention. cmux is keeping an unselected provider disabled."
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                Button(L10n.string("mobile.iroh.refresh", defaultValue: "Refresh Relay Policy")) {
                    model.refresh()
                }
            } header: {
                Text(L10n.string("mobile.iroh.diagnostics", defaultValue: "Diagnostics"))
            }
        }
        .disabled(model.isMutating)
        .navigationTitle(L10n.string("mobile.iroh.title", defaultValue: "Iroh and Relays"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.observe() }
        .sheet(isPresented: $showsCustomEditor) {
            MobileIrohCustomRelayEditor(relay: editedCustomRelay) { relay, secret in
                await model.upsertCustomRelay(relay, deviceSecret: secret)
            }
        }
        .alert(
            L10n.string("mobile.iroh.saveFailed", defaultValue: "Could Not Save Networking Settings"),
            isPresented: Binding(
                get: { model.showsSaveError },
                set: { if !$0 { model.clearSaveError() } }
            )
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "mobile.iroh.saveFailed.message",
                defaultValue: "Your previous networking configuration is still active. Check your account connection and values, then try again."
            ))
        }
        .confirmationDialog(
            L10n.string("mobile.iroh.custom.remove.confirm", defaultValue: "Remove this custom relay?"),
            isPresented: Binding(
                get: { pendingCustomRemovalID != nil },
                set: { if !$0 { pendingCustomRemovalID = nil } }
            )
        ) {
            Button(L10n.string("mobile.common.remove", defaultValue: "Remove"), role: .destructive) {
                if let id = pendingCustomRemovalID { model.removeCustomRelay(id: id) }
                pendingCustomRemovalID = nil
            }
        }
    }

    private enum PreferenceChoice: Hashable {
        case automatic
        case managed
        case custom
    }

    private var preferenceChoice: PreferenceChoice {
        switch model.snapshot.preference {
        case .automatic: .automatic
        case .managed: .managed
        case .custom: .custom
        }
    }

    private var preferenceBinding: Binding<PreferenceChoice> {
        Binding(
            get: { preferenceChoice },
            set: { choice in
                switch choice {
                case .automatic:
                    model.setPreference(.automatic)
                case .managed:
                    let selected = Set(model.snapshot.managedRelays.filter(\.isSelected).map(\.id))
                    let all = Set(model.snapshot.managedRelays.map(\.id))
                    model.setPreference(.managed(selected.isEmpty ? all : selected))
                case .custom:
                    model.setPreference(.custom)
                }
            }
        )
    }

    private func managedRelayBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.snapshot.managedRelays.first(where: { $0.id == id })?.isSelected == true },
            set: { enabled in
                var selected = Set(model.snapshot.managedRelays.filter(\.isSelected).map(\.id))
                if enabled { selected.insert(id) } else { selected.remove(id) }
                guard !selected.isEmpty else { return }
                model.setPreference(.managed(selected))
            }
        )
    }

    private var editedCustomRelay: CmxIrohSettingsSnapshot.CustomRelay? {
        guard let editedCustomRelayID else { return nil }
        return model.snapshot.customRelays.first { $0.id == editedCustomRelayID }
    }

    private func customRelaySubtitle(_ relay: CmxIrohSettingsSnapshot.CustomRelay) -> String {
        switch model.testResults[relay.id] {
        case .reachable:
            L10n.string("mobile.iroh.test.reachable", defaultValue: "Reachable")
        case .failed:
            L10n.string("mobile.iroh.test.failed", defaultValue: "Unreachable")
        case .incomplete:
            L10n.string("mobile.iroh.test.incomplete", defaultValue: "Test Unavailable")
        case nil:
            String(
                format: L10n.string("mobile.iroh.custom.summary", defaultValue: "%1$@ · %2$@"),
                relay.provider,
                relay.region
            )
        }
    }

    private var runtimeStatusText: String {
        switch model.snapshot.runtimeStatus {
        case .inactive: L10n.string("mobile.iroh.status.inactive", defaultValue: "Inactive")
        case .starting: L10n.string("mobile.iroh.status.starting", defaultValue: "Starting")
        case .active: L10n.string("mobile.iroh.status.active", defaultValue: "Iroh Active")
        case .direct: L10n.string("mobile.iroh.status.direct", defaultValue: "Direct Peer-to-Peer")
        case .relayed: L10n.string("mobile.iroh.status.relayed", defaultValue: "Relayed")
        case .privateNetwork: L10n.string("mobile.iroh.status.private", defaultValue: "Private Network")
        case .degraded: L10n.string("mobile.iroh.status.degraded", defaultValue: "Direct-Only")
        }
    }

    private var policyStatusText: String {
        switch model.snapshot.policySource {
        case .server: L10n.string("mobile.iroh.policy.server", defaultValue: "Verified from cmux")
        case .cached: L10n.string("mobile.iroh.policy.cached", defaultValue: "Last Verified Catalog")
        case .unavailable: L10n.string("mobile.iroh.policy.unavailable", defaultValue: "Unavailable")
        }
    }
}
#endif
