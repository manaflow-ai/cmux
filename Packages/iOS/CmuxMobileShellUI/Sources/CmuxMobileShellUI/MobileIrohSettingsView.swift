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

            MobileIrohDiagnosticsSection(
                connectionStatus: runtimeStatusText,
                policyStatus: policyStatusText,
                lastSuccessfulConnection: model.diagnosticReport.lastConnectionSuccessDate,
                lastFailureDate: model.diagnosticReport.lastFailureDate,
                lastFailureCategory: diagnosticFailureKindText,
                eventCount: model.diagnosticReport.events.count,
                exportText: model.diagnosticExportText,
                needsAttention: !model.snapshot.staleRelayIDs.isEmpty || model.snapshot.failureDescription != nil,
                refresh: model.refresh,
                clear: {
                    Task { await model.clearDiagnosticReport() }
                }
            )
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

private extension MobileIrohSettingsView {
    private var diagnosticFailureKindText: String {
        switch model.diagnosticReport.lastFailureKind {
        case nil, .some(.none):
            L10n.string("mobile.iroh.diagnostics.failure.none", defaultValue: "None")
        case .some(.offline):
            L10n.string("mobile.iroh.diagnostics.failure.offline", defaultValue: "Offline")
        case .some(.timedOut):
            L10n.string("mobile.iroh.diagnostics.failure.timedOut", defaultValue: "Timed Out")
        case .some(.connectionRefused):
            L10n.string(
                "mobile.iroh.diagnostics.failure.connectionRefused",
                defaultValue: "Connection Refused"
            )
        case .some(.hostUnreachable):
            L10n.string("mobile.iroh.diagnostics.failure.hostUnreachable", defaultValue: "Host Unreachable")
        case .some(.permissionDenied):
            L10n.string("mobile.iroh.diagnostics.failure.permissionDenied", defaultValue: "Permission Denied")
        case .some(.dnsFailed):
            L10n.string("mobile.iroh.diagnostics.failure.dnsFailed", defaultValue: "Name Resolution Failed")
        case .some(.secureChannelFailed):
            L10n.string("mobile.iroh.diagnostics.failure.secureChannelFailed", defaultValue: "Secure Channel Failed")
        case .some(.unsupportedRoute):
            L10n.string("mobile.iroh.diagnostics.failure.unsupportedRoute", defaultValue: "Unsupported Route")
        case .some(.noRoute):
            L10n.string("mobile.iroh.diagnostics.failure.noRoute", defaultValue: "No Route Available")
        case .some(.credentialUnavailable):
            L10n.string(
                "mobile.iroh.diagnostics.failure.credentialUnavailable",
                defaultValue: "Credentials Unavailable"
            )
        case .some(.policyUnavailable):
            L10n.string("mobile.iroh.diagnostics.failure.policyUnavailable", defaultValue: "Relay Policy Unavailable")
        case .some(.endpointUnavailable):
            L10n.string("mobile.iroh.diagnostics.failure.endpointUnavailable", defaultValue: "Endpoint Unavailable")
        case .some(.identityMismatch):
            L10n.string(
                "mobile.iroh.diagnostics.failure.identityMismatch",
                defaultValue: "Endpoint Identity Mismatch"
            )
        case .some(.admissionDenied):
            L10n.string(
                "mobile.iroh.diagnostics.failure.admissionDenied",
                defaultValue: "Connection Admission Denied"
            )
        case .some(.authorizationFailed):
            L10n.string(
                "mobile.iroh.diagnostics.failure.authorizationFailed",
                defaultValue: "Authorization Failed"
            )
        case .some(.accountMismatch):
            L10n.string("mobile.iroh.diagnostics.failure.accountMismatch", defaultValue: "Account Mismatch")
        case .some(.protocolViolation):
            L10n.string("mobile.iroh.diagnostics.failure.protocolViolation", defaultValue: "Protocol Error")
        case .some(.connectionClosed):
            L10n.string(
                "mobile.iroh.diagnostics.failure.connectionClosed",
                defaultValue: "Connection Closed"
            )
        case .some(.superseded):
            L10n.string(
                "mobile.iroh.diagnostics.failure.superseded",
                defaultValue: "Replaced by a Newer Attempt"
            )
        case .some(.cancelled):
            L10n.string("mobile.iroh.diagnostics.failure.cancelled", defaultValue: "Cancelled")
        case .some(.unknown):
            L10n.string("mobile.iroh.diagnostics.failure.unknown", defaultValue: "Unknown")
        }
    }
}

@MainActor
private struct MobileIrohDiagnosticsSection: View {
    let connectionStatus: String
    let policyStatus: String
    let lastSuccessfulConnection: Date?
    let lastFailureDate: Date?
    let lastFailureCategory: String
    let eventCount: Int
    let exportText: String
    let needsAttention: Bool
    let refresh: () -> Void
    let clear: () -> Void

    @State private var showsClearConfirmation = false

    var body: some View {
        Section {
            LabeledContent(
                L10n.string("mobile.iroh.status", defaultValue: "Connection"),
                value: connectionStatus
            )
            LabeledContent(
                L10n.string("mobile.iroh.policy", defaultValue: "Relay Policy"),
                value: policyStatus
            )
            LabeledContent {
                diagnosticDate(lastSuccessfulConnection)
            } label: {
                Text(L10n.string(
                    "mobile.iroh.diagnostics.lastSuccess",
                    defaultValue: "Last Successful Connection"
                ))
            }
            LabeledContent(
                L10n.string("mobile.iroh.diagnostics.lastFailure", defaultValue: "Last Failure"),
                value: lastFailureCategory
            )
            LabeledContent {
                diagnosticDate(lastFailureDate)
            } label: {
            Text(L10n.string(
                "mobile.iroh.diagnostics.lastFailureTime",
                defaultValue: "Failure Time"
            ))
            }
            LabeledContent {
                Text(eventCount, format: .number)
            } label: {
                Text(L10n.string("mobile.iroh.diagnostics.eventCount", defaultValue: "Recorded Events"))
            }

            if needsAttention {
                Label(
                    L10n.string(
                        "mobile.iroh.attention",
                        defaultValue: """
                        Your relay preference needs attention. cmux is keeping an unselected provider \
                        disabled.
                        """
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            Button(L10n.string("mobile.iroh.refresh", defaultValue: "Refresh Relay Policy"), action: refresh)

            ShareLink(item: exportText) {
                Label(
                    L10n.string("mobile.iroh.diagnostics.share", defaultValue: "Share Safe Report"),
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(exportText.isEmpty)
            .accessibilityIdentifier("MobileIrohShareDiagnosticReport")

            Button(role: .destructive) {
                showsClearConfirmation = true
            } label: {
                Label(
                    L10n.string("mobile.iroh.diagnostics.clear", defaultValue: "Clear Report"),
                    systemImage: "trash"
                )
            }
            .disabled(eventCount == 0)
            .accessibilityIdentifier("MobileIrohClearDiagnosticReport")
        } header: {
            Text(L10n.string("mobile.iroh.diagnostics", defaultValue: "Diagnostics"))
        } footer: {
            Text(L10n.string(
                "mobile.iroh.diagnostics.privacy",
                defaultValue: """
                This report remains available while disconnected. It excludes terminal content, account and \
                endpoint identities, network addresses, relay URLs, credentials, and raw errors. Nothing leaves \
                this device until you share it.
                """
            ))
        }
        .confirmationDialog(
            L10n.string("mobile.iroh.diagnostics.clear.confirm", defaultValue: "Clear this diagnostic report?"),
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("mobile.iroh.diagnostics.clear", defaultValue: "Clear Report"), role: .destructive) {
                clear()
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "mobile.iroh.diagnostics.clear.message",
                defaultValue: "This permanently removes the connection timeline stored on this device."
            ))
        }
    }

    @ViewBuilder
    private func diagnosticDate(_ date: Date?) -> some View {
        if let date {
            Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
        } else {
            Text(L10n.string("mobile.iroh.diagnostics.notRecorded", defaultValue: "Not Recorded"))
                .foregroundStyle(.secondary)
        }
    }
}
#endif
