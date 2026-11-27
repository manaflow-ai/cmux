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
    @State private var showsResetConfirmation = false

    init(
        controller: any CmxIrohSettingsControlling,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        _model = State(initialValue: MobileIrohSettingsModel(
            controller: controller,
            diagnosticLog: diagnosticLog
        ))
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

                // The catalog refresh lived in the removed Diagnostics section;
                // it acts on the relay policy, so it belongs with the relays.
                Button(
                    L10n.string("mobile.iroh.refresh", defaultValue: "Refresh Relay Policy"),
                    action: model.refresh
                )
            } header: {
                Text(L10n.string("mobile.iroh.relays", defaultValue: "Relays"))
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
                Toggle(isOn: pathPreferenceBinding) {
                    Text(L10n.string(
                        "mobile.iroh.neverUseRelays",
                        defaultValue: "Never Use Relays"
                    ))
                }
                .accessibilityIdentifier("MobileIrohNeverUseRelays")
            } footer: {
                Text(L10n.string(
                    "mobile.iroh.pathPreference.footer",
                    defaultValue: "When enabled, cmux requires a reachable direct, local-network, or private-network path and will not fall back to a relay. Applies on the next reconnect."
                ))
            }

            // Per-Mac private addresses and the per-Mac connection check moved
            // to each computer's detail screen; transport diagnostics moved to
            // the Settings top-level Diagnostics section. This screen owns only
            // app-wide relay configuration.
            #if DEBUG
            if let mode = model.snapshot.debugTransportVerificationMode {
                MobileIrohDebugTransportSection(
                    mode: mode,
                    setMode: model.setDebugTransportVerificationMode
                )
            }
            #endif
        }
        .disabled(model.isMutating)
        .navigationTitle(L10n.string("mobile.iroh.title", defaultValue: "Networking"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsResetConfirmation = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel(L10n.string(
                    "mobile.iroh.reset",
                    defaultValue: "Reset to Defaults"
                ))
                .accessibilityIdentifier("MobileIrohResetDefaults")
                .disabled(model.isMutating)
            }
        }
        .task { await model.observe() }
        .onDisappear { model.cancelOperations() }
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
                defaultValue: "Your previous networking configuration is still active. Check the values, then try again."
            ))
        }
        .alert(
            L10n.string(
                "mobile.iroh.reset.title",
                defaultValue: "Reset Networking Settings?"
            ),
            isPresented: $showsResetConfirmation
        ) {
            Button(
                L10n.string("mobile.iroh.reset.confirm", defaultValue: "Reset"),
                role: .destructive
            ) {
                model.resetToDefaults()
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "mobile.iroh.reset.message",
                defaultValue: "Relay and path preferences will return to Automatic. Saved custom relays and private addresses will remain, but private addresses will be disabled."
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

    private var pathPreferenceBinding: Binding<Bool> {
        Binding(
            get: { model.snapshot.pathPreference == .neverUseRelays },
            set: { model.setPathPreference($0 ? .neverUseRelays : .automatic) }
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

}


#if DEBUG
@MainActor
private struct MobileIrohDebugTransportSection: View {
    let mode: CmxIrohTransportVerificationMode
    let setMode: (CmxIrohTransportVerificationMode) -> Void

    var body: some View {
        Section {
            Picker(
                L10n.string(
                    "mobile.iroh.debug.transportMode",
                    defaultValue: "Transport Mode"
                ),
                selection: Binding(
                    get: { mode },
                    set: setMode
                )
            ) {
                Text(L10n.string(
                    "mobile.iroh.debug.transportMode.automatic",
                    defaultValue: "Automatic"
                ))
                .tag(CmxIrohTransportVerificationMode.automatic)
                Text(L10n.string(
                    "mobile.iroh.debug.transportMode.relayOnly",
                    defaultValue: "Relay Only"
                ))
                .tag(CmxIrohTransportVerificationMode.relayOnly)
                Text(L10n.string(
                    "mobile.iroh.debug.transportMode.directOnly",
                    defaultValue: "No Relay (Direct Only)"
                ))
                .tag(CmxIrohTransportVerificationMode.directOnly)
            }
            .accessibilityIdentifier("MobileIrohDebugTransportMode")
        } header: {
            Text(L10n.string(
                "mobile.iroh.debug",
                defaultValue: "Debug Verification"
            ))
        } footer: {
            Text(L10n.string(
                "mobile.iroh.debug.footer",
                defaultValue: "Changing this restarts Iroh without signing out or changing this app's device identity."
            ))
        }
    }
}
#endif

#endif
