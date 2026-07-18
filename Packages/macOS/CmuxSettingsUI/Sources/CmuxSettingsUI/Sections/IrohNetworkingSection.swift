import CMUXMobileCore
import SwiftUI

/// Iroh relay policy, custom relay, and private-path diagnostics.
@MainActor
public struct IrohNetworkingSection: View {
    @State private var model: IrohSettingsModel
    @State private var showsCustomEditor = false
    @State private var editedCustomRelayID: String?
    @State private var pendingCustomRemovalID: String?

    public init(hostActions: SettingsHostActions) {
        _model = State(initialValue: IrohSettingsModel(controller: hostActions.irohSettingsController()))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.networking", defaultValue: "Networking"),
                section: .networking
            )
            relayPolicyCard
            customRelayCard
            privateNetworkCard
            diagnosticsCard
        }
        .task { await model.observe() }
        .sheet(isPresented: $showsCustomEditor) {
            NavigationStack {
                IrohCustomRelayEditor(relay: editedCustomRelay) { relay, secret in
                    await model.upsertCustomRelay(relay, deviceSecret: secret)
                }
            }
        }
        .alert(
            String(localized: "settings.networking.saveFailed", defaultValue: "Could Not Save Networking Settings"),
            isPresented: Binding(
                get: { model.showsSaveError },
                set: { if !$0 { model.clearSaveError() } }
            )
        ) {
            Button(String(localized: "settings.common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "settings.networking.saveFailed.message",
                defaultValue: "Your previous networking configuration is still active. Check your account connection and relay values, then try again."
            ))
        }
        .confirmationDialog(
            String(localized: "settings.networking.custom.remove.confirm", defaultValue: "Remove this custom relay?"),
            isPresented: Binding(
                get: { pendingCustomRemovalID != nil },
                set: { if !$0 { pendingCustomRemovalID = nil } }
            )
        ) {
            Button(String(localized: "settings.common.remove", defaultValue: "Remove"), role: .destructive) {
                if let id = pendingCustomRemovalID { model.removeCustomRelay(id: id) }
                pendingCustomRemovalID = nil
            }
        }
    }

    private var relayPolicyCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:relayPreference",
                String(localized: "settings.networking.relayPreference", defaultValue: "Relay Preference"),
                subtitle: String(
                    localized: "settings.networking.relayPreference.subtitle",
                    defaultValue: "Direct peer-to-peer stays enabled. This controls which relays Iroh may use when a direct path is unavailable."
                ),
                controlWidth: 210
            ) {
                Picker("", selection: preferenceBinding) {
                    Text(String(localized: "settings.networking.preference.automatic", defaultValue: "Automatic"))
                        .tag(PreferenceChoice.automatic)
                    Text(String(localized: "settings.networking.preference.managed", defaultValue: "Selected cmux Relays"))
                        .tag(PreferenceChoice.managed)
                    Text(String(localized: "settings.networking.preference.custom", defaultValue: "Custom Relays"))
                        .tag(PreferenceChoice.custom)
                }
                .labelsHidden()
                .disabled(model.isMutating)
                .accessibilityIdentifier("SettingsIrohRelayPreferencePicker")
            }

            if preferenceChoice == .managed {
                ForEach(model.snapshot.managedRelays) { relay in
                    SettingsCardDivider()
                    SettingsCardRow(
                        configurationReview: .settingsOnly,
                        searchAnchorID: "setting:networking:managed:\(relay.id)",
                        relay.region,
                        subtitle: relay.provider
                    ) {
                        Toggle("", isOn: managedRelayBinding(relay.id))
                            .labelsHidden()
                            .disabled(model.isMutating)
                            .accessibilityIdentifier("SettingsIrohManagedRelay-\(relay.id)")
                    }
                }
            }

            SettingsCardNote(String(
                localized: "settings.networking.relayPolicy.note",
                defaultValue: "cmux downloads a signed relay catalog. Fleet additions, removals, and regional changes do not require an app update."
            ))
        }
    }

    private var customRelayCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:customRelays",
                String(localized: "settings.networking.custom.title", defaultValue: "Custom Relays"),
                subtitle: String(
                    localized: "settings.networking.custom.subtitle",
                    defaultValue: "Use relays you operate or obtain from another provider."
                )
            ) {
                Button(String(localized: "settings.networking.custom.add.short", defaultValue: "Add…")) {
                    editedCustomRelayID = nil
                    showsCustomEditor = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsIrohAddCustomRelay")
            }

            ForEach(model.snapshot.customRelays) { relay in
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    searchAnchorID: "setting:networking:custom:\(relay.id)",
                    relay.displayName,
                    subtitle: customRelaySubtitle(relay)
                ) {
                    HStack(spacing: 6) {
                        Button(String(localized: "settings.networking.test", defaultValue: "Test")) {
                            model.testCustomRelay(id: relay.id)
                        }
                        Button(String(localized: "settings.common.edit", defaultValue: "Edit")) {
                            editedCustomRelayID = relay.id
                            showsCustomEditor = true
                        }
                        Button(role: .destructive) {
                            pendingCustomRemovalID = relay.id
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(String(localized: "settings.common.remove", defaultValue: "Remove"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            SettingsCardNote(String(
                localized: "settings.networking.custom.note",
                defaultValue: "Relay addresses sync with your account. Provider secrets stay only in each device's secure storage. Missing secrets never fall back to cmux relays."
            ))
        }
    }

    private var privateNetworkCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:privateNetworks",
                String(localized: "settings.networking.private.title", defaultValue: "Private Networks"),
                subtitle: String(
                    localized: "settings.networking.private.subtitle",
                    defaultValue: "Iroh discovers usable LAN and VPN paths after authenticating the other device."
                )
            ) {
                Text(String(localized: "settings.networking.private.automatic", defaultValue: "Automatic"))
                    .foregroundStyle(.secondary)
            }

            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:tailscaleCompatibility",
                String(localized: "settings.networking.private.tailscale", defaultValue: "Tailscale Compatibility"),
                subtitle: String(
                    localized: "settings.networking.private.tailscale.subtitle",
                    defaultValue: "Retained for released clients and networks where Iroh cannot connect."
                )
            ) {
                Text(String(localized: "settings.networking.private.automatic", defaultValue: "Automatic"))
                    .foregroundStyle(.secondary)
            }

            SettingsCardNote(String(
                localized: "settings.networking.private.note.short",
                defaultValue: "Custom raw TCP routes are not accepted because they cannot prove the remote Mac. Iroh private paths stay encrypted and bound to its exact EndpointID."
            ))
        }
    }

    private var diagnosticsCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:status",
                String(localized: "settings.networking.status", defaultValue: "Iroh Status"),
                subtitle: runtimeStatusText
            ) {
                Button(String(localized: "settings.networking.refresh", defaultValue: "Refresh")) {
                    model.refresh()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:policy",
                String(localized: "settings.networking.policy", defaultValue: "Relay Policy"),
                subtitle: policyStatusText
            ) {
                Image(systemName: policySymbol)
                    .foregroundStyle(model.snapshot.policySource == .unavailable ? .orange : .secondary)
            }
            #if DEBUG
            if let debugRelayOnlyEnabled = model.snapshot.debugRelayOnlyEnabled {
                SettingsCardDivider()
                IrohDebugRelayOnlyRow(
                    isEnabled: debugRelayOnlyEnabled,
                    isMutating: model.isMutating,
                    setEnabled: { model.setDebugRelayOnly($0) }
                )
            }
            #endif
            IrohDiagnosticsReportRows(
                report: model.diagnosticReport,
                exportText: model.diagnosticExportText,
                isMutating: model.isMutating,
                clear: { await model.clearDiagnosticReport() }
            )
            if !model.snapshot.staleRelayIDs.isEmpty || model.snapshot.failureDescription != nil {
                SettingsCardNote(String(
                    localized: "settings.networking.attention",
                    defaultValue: "Your saved relay choice needs attention. Direct Iroh remains available, but cmux will not substitute an unselected relay."
                ))
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
                    let current = Set(model.snapshot.managedRelays.filter(\.isSelected).map(\.id))
                    let fallback = Set(model.snapshot.managedRelays.map(\.id))
                    model.setPreference(.managed(current.isEmpty ? fallback : current))
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
        let testStatus: String
        switch model.testResults[relay.id] {
        case .reachable:
            testStatus = String(localized: "settings.networking.test.reachable", defaultValue: "reachable")
        case .failed:
            testStatus = String(localized: "settings.networking.test.failed", defaultValue: "unreachable")
        case .incomplete:
            testStatus = String(localized: "settings.networking.test.incomplete", defaultValue: "test unavailable")
        case nil:
            testStatus = relay.region
        }
        return String(
            format: String(
                localized: "settings.networking.custom.summary",
                defaultValue: "%1$@ · %2$@"
            ),
            relay.provider,
            testStatus
        )
    }

    private var runtimeStatusText: String {
        switch model.snapshot.runtimeStatus {
        case .inactive:
            String(localized: "settings.networking.status.inactive", defaultValue: "Inactive")
        case .starting:
            String(localized: "settings.networking.status.starting", defaultValue: "Starting")
        case .active:
            String(localized: "settings.networking.status.active", defaultValue: "Iroh endpoint active")
        case .direct:
            String(localized: "settings.networking.status.direct", defaultValue: "Connected directly peer-to-peer")
        case let .relayed(provider, region):
            String(localized: "settings.networking.status.relayed", defaultValue: "Connected through \(provider), \(region)")
        case let .privateNetwork(displayName):
            if displayName.isEmpty {
                String(
                    localized: "settings.networking.status.private.generic",
                    defaultValue: "Connected through a private network"
                )
            } else {
                String(
                    localized: "settings.networking.status.private",
                    defaultValue: "Connected through \(displayName)"
                )
            }
        case .degraded:
            String(localized: "settings.networking.status.degraded", defaultValue: "Direct-only until relay settings recover")
        }
    }

    private var policyStatusText: String {
        switch model.snapshot.policySource {
        case .server:
            String(localized: "settings.networking.policy.server", defaultValue: "Verified from cmux")
        case .cached:
            String(localized: "settings.networking.policy.cached", defaultValue: "Using the last verified catalog")
        case .unavailable:
            String(localized: "settings.networking.policy.unavailable", defaultValue: "No valid catalog available")
        }
    }

    private var policySymbol: String {
        model.snapshot.policySource == .unavailable ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
    }
}

@MainActor
private struct IrohDiagnosticsReportRows: View {
    let report: DiagnosticReport
    let exportText: String
    let isMutating: Bool
    let clear: @MainActor @Sendable () async -> Void

    @State private var showsClearConfirmation = false

    var body: some View {
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:networking:diagnostics:lastConnection",
            String(
                localized: "settings.networking.diagnostics.lastSuccess",
                defaultValue: "Last Successful Connection"
            )
        ) {
            Text(diagnosticDate(report.lastConnectionSuccessDate))
                .foregroundStyle(.secondary)
        }

        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:networking:diagnostics:lastFailure",
            String(localized: "settings.networking.diagnostics.lastFailure", defaultValue: "Last Failure"),
            subtitle: diagnosticDate(report.lastFailureDate),
            controlWidth: 210
        ) {
            Text(failureKindText)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }

        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:networking:diagnostics:eventCount",
            String(localized: "settings.networking.diagnostics.eventCount", defaultValue: "Recorded Events")
        ) {
            Text(report.events.count, format: .number)
                .foregroundStyle(.secondary)
        }

        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:networking:diagnostics:report",
            String(localized: "settings.networking.diagnostics.report", defaultValue: "Connection Report"),
            subtitle: String(
                localized: "settings.networking.diagnostics.report.subtitle",
                defaultValue: "Share a bounded, privacy-safe connection timeline with support."
            )
        ) {
            HStack(spacing: 6) {
                ShareLink(item: exportText) {
                    Label(
                        String(
                            localized: "settings.networking.diagnostics.share",
                            defaultValue: "Share…"
                        ),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .disabled(exportText.isEmpty || isMutating)
                .accessibilityIdentifier("SettingsIrohShareDiagnosticReport")

                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(report.events.isEmpty || isMutating)
                .accessibilityLabel(String(
                    localized: "settings.networking.diagnostics.clear",
                    defaultValue: "Clear Report"
                ))
                .accessibilityIdentifier("SettingsIrohClearDiagnosticReport")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }

        SettingsCardNote(String(
            localized: "settings.networking.diagnostics.privacy",
            defaultValue: "The report stays on this Mac until you share it. It excludes terminal content, account and endpoint identities, network addresses, relay URLs, credentials, and raw errors."
        ))
        .confirmationDialog(
            String(
                localized: "settings.networking.diagnostics.clear.confirm",
                defaultValue: "Clear this diagnostic report?"
            ),
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "settings.networking.diagnostics.clear", defaultValue: "Clear Report"),
                role: .destructive
            ) {
                Task { await clear() }
            }
            Button(String(localized: "settings.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "settings.networking.diagnostics.clear.message",
                defaultValue: "This permanently removes the connection timeline stored on this Mac."
            ))
        }
    }

    private func diagnosticDate(_ date: Date?) -> String {
        guard let date else {
            return String(
                localized: "settings.networking.diagnostics.notRecorded",
                defaultValue: "Not Recorded"
            )
        }
        return date.formatted(
            .dateTime.year().month(.abbreviated).day().hour().minute().second()
        )
    }

    private var failureKindText: String {
        switch report.lastFailureKind {
        case nil, .some(.none):
            String(localized: "settings.networking.diagnostics.failure.none", defaultValue: "None")
        case .some(.offline):
            String(localized: "settings.networking.diagnostics.failure.offline", defaultValue: "Offline")
        case .some(.timedOut):
            String(localized: "settings.networking.diagnostics.failure.timedOut", defaultValue: "Timed Out")
        case .some(.connectionRefused):
            String(
                localized: "settings.networking.diagnostics.failure.connectionRefused",
                defaultValue: "Connection Refused"
            )
        case .some(.hostUnreachable):
            String(
                localized: "settings.networking.diagnostics.failure.hostUnreachable",
                defaultValue: "Host Unreachable"
            )
        case .some(.permissionDenied):
            String(
                localized: "settings.networking.diagnostics.failure.permissionDenied",
                defaultValue: "Permission Denied"
            )
        case .some(.dnsFailed):
            String(
                localized: "settings.networking.diagnostics.failure.dnsFailed",
                defaultValue: "Name Resolution Failed"
            )
        case .some(.secureChannelFailed):
            String(
                localized: "settings.networking.diagnostics.failure.secureChannelFailed",
                defaultValue: "Secure Channel Failed"
            )
        case .some(.unsupportedRoute):
            String(
                localized: "settings.networking.diagnostics.failure.unsupportedRoute",
                defaultValue: "Unsupported Route"
            )
        case .some(.noRoute):
            String(
                localized: "settings.networking.diagnostics.failure.noRoute",
                defaultValue: "No Route Available"
            )
        case .some(.credentialUnavailable):
            String(
                localized: "settings.networking.diagnostics.failure.credentialUnavailable",
                defaultValue: "Credentials Unavailable"
            )
        case .some(.policyUnavailable):
            String(
                localized: "settings.networking.diagnostics.failure.policyUnavailable",
                defaultValue: "Relay Policy Unavailable"
            )
        case .some(.endpointUnavailable):
            String(
                localized: "settings.networking.diagnostics.failure.endpointUnavailable",
                defaultValue: "Endpoint Unavailable"
            )
        case .some(.identityMismatch):
            String(
                localized: "settings.networking.diagnostics.failure.identityMismatch",
                defaultValue: "Endpoint Identity Mismatch"
            )
        case .some(.admissionDenied):
            String(
                localized: "settings.networking.diagnostics.failure.admissionDenied",
                defaultValue: "Connection Admission Denied"
            )
        case .some(.authorizationFailed):
            String(
                localized: "settings.networking.diagnostics.failure.authorizationFailed",
                defaultValue: "Authorization Failed"
            )
        case .some(.accountMismatch):
            String(
                localized: "settings.networking.diagnostics.failure.accountMismatch",
                defaultValue: "Account Mismatch"
            )
        case .some(.protocolViolation):
            String(
                localized: "settings.networking.diagnostics.failure.protocolViolation",
                defaultValue: "Protocol Error"
            )
        case .some(.connectionClosed):
            String(
                localized: "settings.networking.diagnostics.failure.connectionClosed",
                defaultValue: "Connection Closed"
            )
        case .some(.superseded):
            String(
                localized: "settings.networking.diagnostics.failure.superseded",
                defaultValue: "Replaced by a Newer Attempt"
            )
        case .some(.cancelled):
            String(localized: "settings.networking.diagnostics.failure.cancelled", defaultValue: "Cancelled")
        case .some(.unknown):
            String(localized: "settings.networking.diagnostics.failure.unknown", defaultValue: "Unknown")
        }
    }
}

#if DEBUG
private struct IrohDebugRelayOnlyRow: View {
    let isEnabled: Bool
    let isMutating: Bool
    let setEnabled: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:networking:debugRelayOnly",
            String(
                localized: "settings.networking.debug.relayOnly",
                defaultValue: "Relay-Only Verification"
            ),
            subtitle: String(
                localized: "settings.networking.debug.relayOnly.subtitle",
                defaultValue: "Debug builds only. Keeps authenticated Iroh sessions on relays so the relay path can be verified."
            )
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in setEnabled(newValue) }
                )
            )
            .labelsHidden()
            .disabled(isMutating)
            .accessibilityIdentifier("SettingsIrohDebugRelayOnly")
        }
    }
}
#endif
