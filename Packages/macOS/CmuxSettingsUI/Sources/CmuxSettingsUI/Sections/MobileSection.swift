import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Mobile** section — Mac-side controls for pairing and syncing with
/// cmux on iOS: the pairing-host toggle, the preferred listener port (with a
/// live bound-port indicator), an optional display-name override, and
/// connection/route diagnostics.
@MainActor
public struct MobileSection: View {
    @State private var transportMode: DefaultsValueModel<MobileTransportMode>
    @State private var irohRelayURL: DefaultsValueModel<String>
    @State private var port: DefaultsValueModel<Int>
    @State private var displayName: DefaultsValueModel<String>
    @State private var status: MobilePairingStatusModel

    /// The user's in-progress port edit, or `nil` when the field should track
    /// the persisted value. Local so editing does not rebind the listener; only
    /// the **Apply** button does, after checking the port is free. `nil` lets the
    /// field reflect `port.current` once `DefaultsValueModel` has loaded the
    /// saved value (it seeds the catalog default first, then yields the real one).
    @State private var editedPort: Int?
    /// Result of the most recent Apply, shown inline. Cleared when the edit changes.
    @State private var applyResult: MobilePairingPortApplyResult?
    /// The user's in-progress relay-URL edit, or `nil` when the field tracks the
    /// persisted value. Local so typing does not rebind the iroh lane; only the
    /// **Apply** button commits a validated URL.
    @State private var editedRelayURL: String?
    /// Guards against overlapping Apply taps while a probe is in flight.
    @State private var isApplying = false

    /// Host bridge: opens the pairing window, applies the port (availability
    /// checked), and supplies the live pairing status and default display name.
    private let hostActions: SettingsHostActions

    private static let columnWidth: CGFloat = 196

    /// Creates a Mobile settings section bound to the supplied settings stores.
    ///
    /// - Parameters:
    ///   - defaultsStore: UserDefaults-backed store for the pairing settings.
    ///   - catalog: The settings catalog defining the mobile keys.
    ///   - hostActions: Host bridge for the pairing window, port apply, and the
    ///     live pairing status the package can't produce itself.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        _transportMode = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSTransportMode))
        _irohRelayURL = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSIrohRelayURL))
        _port = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingPort))
        _displayName = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingDisplayName))
        _status = State(initialValue: MobilePairingStatusModel(hostActions: hostActions))
        self.hostActions = hostActions
    }

    /// The value shown in the field: the user's edit if any, otherwise the
    /// persisted port (which updates once it loads).
    private var draftPort: Int {
        editedPort ?? port.current
    }

    /// The port currently in effect: the bound port when running, otherwise the
    /// persisted preference. Apply is offered only when the draft differs from it.
    private var effectivePort: Int {
        status.current?.boundPort ?? port.current
    }

    private var isDraftValid: Bool {
        (1...65535).contains(draftPort)
    }

    private var isTailscaleMode: Bool { transportMode.current == .tailscale }
    private var isOwnRelayMode: Bool { transportMode.current == .ownRelay }

    /// The relay-URL value shown in the field: the user's in-progress edit if
    /// any, otherwise the persisted value. Like the port field, edits are local
    /// and only **Apply** commits, so the iroh lane is not rebound per keystroke.
    private var draftRelayURL: String {
        editedRelayURL ?? irohRelayURL.current
    }

    /// In ownRelay mode the relay URL must be a non-empty `https://` URL.
    private var isRelayURLValid: Bool {
        let trimmed = draftRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased().hasPrefix("https://") else { return false }
        return URL(string: trimmed) != nil
    }

    private func applyRelayURL() {
        let trimmed = draftRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRelayURLValid, trimmed != irohRelayURL.current else { return }
        irohRelayURL.set(trimmed)
        editedRelayURL = nil
    }

    /// The Mobile settings section content.
    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.mobile", defaultValue: "Mobile"), section: .mobile)
            SettingsCard {
                pairDeviceRow
                SettingsCardDivider()
                transportModeRow
                if isOwnRelayMode {
                    SettingsCardDivider()
                    relayURLRow
                }
                if isTailscaleMode {
                    SettingsCardDivider()
                    portRow
                    boundPortStatusRow
                }
                SettingsCardDivider()
                displayNameRow
                SettingsCardDivider()
                diagnostics
                if isTailscaleMode {
                    SettingsCardNote(String(
                        localized: "settings.mobile.port.note",
                        defaultValue: "Click Apply to change the port. cmux checks the port is free first: if it's in use, the current listener keeps running untouched; if it's free, it rebinds and connected devices reconnect on the new port."
                    ))
                }
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            transportMode,
            irohRelayURL,
            port,
            displayName,
            status,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var pairDeviceRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:mobile:pairDevice",
            String(localized: "settings.mobile.pairDevice", defaultValue: "Pair a Device"),
            subtitle: String(localized: "settings.mobile.pairDevice.subtitle", defaultValue: "Show a QR code to pair your iPhone or iPad with this Mac.")
        ) {
            Button(String(localized: "settings.mobile.pairDevice.button", defaultValue: "Pair…")) {
                hostActions.openMobilePairingWindow()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsMobilePairDeviceButton")
        }
    }

    @ViewBuilder
    private var transportModeRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:transportMode",
            String(localized: "settings.mobile.transportMode", defaultValue: "Mobile Connection"),
            subtitle: transportModeSubtitle,
            controlWidth: Self.columnWidth
        ) {
            Picker("", selection: Binding(get: { transportMode.current }, set: { transportMode.set($0) })) {
                ForEach(MobileTransportMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsMobileTransportModePicker")
        }
    }

    private var transportModeSubtitle: String {
        switch transportMode.current {
        case .cmuxRelay:
            return String(localized: "settings.mobile.transportMode.subtitle.cmuxRelay", defaultValue: "iPhones and iPads attach over an encrypted iroh connection via cmux's relay. No Tailscale or shared network needed.")
        case .ownRelay:
            return String(localized: "settings.mobile.transportMode.subtitle.ownRelay", defaultValue: "Attach over iroh using a relay server you run yourself.")
        case .tailscale:
            return String(localized: "settings.mobile.transportMode.subtitle.tailscale", defaultValue: "Attach over your Tailscale network on a TCP port. No relay involved.")
        }
    }

    @ViewBuilder
    private var relayURLRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.mobile.relayURL", defaultValue: "Relay URL"),
            subtitle: String(localized: "settings.mobile.relayURL.subtitle", defaultValue: "The https:// address of the iroh-relay you run (for example https://relay.example.com)."),
            controlWidth: 330
        ) {
            HStack(spacing: 8) {
                TextField(
                    "https://relay.example.com",
                    text: Binding(get: { draftRelayURL }, set: { editedRelayURL = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { applyRelayURL() }
                .accessibilityIdentifier("SettingsMobileRelayURLField")
                Button(String(localized: "settings.mobile.relayURL.apply", defaultValue: "Apply")) {
                    applyRelayURL()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isRelayURLValid || draftRelayURL.trimmingCharacters(in: .whitespacesAndNewlines) == irohRelayURL.current)
                .accessibilityIdentifier("SettingsMobileRelayURLApplyButton")
            }
        }
        if !isRelayURLValid {
            statusCaption {
                Label(
                    String(localized: "settings.mobile.relayURL.invalid", defaultValue: "Enter an https:// relay URL so your devices can reach this Mac."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var portRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:iOSPairingPort",
            String(localized: "settings.mobile.port", defaultValue: "Pairing Port"),
            subtitle: String(localized: "settings.mobile.port.subtitle", defaultValue: "Preferred TCP port for the iOS pairing listener (1–65535).")
        ) {
            HStack(spacing: 8) {
                TextField(
                    "",
                    value: Binding(get: { draftPort }, set: { editedPort = $0 }),
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .onChange(of: editedPort) { applyResult = nil }
                .onSubmit { applyDraftPort() }
                .accessibilityIdentifier("SettingsMobilePairingPortField")

                Button(String(localized: "settings.mobile.port.apply", defaultValue: "Apply")) {
                    applyDraftPort()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isApplying || !isDraftValid || draftPort == effectivePort)
                .accessibilityIdentifier("SettingsMobilePairingPortApplyButton")
            }
        }
    }

    private func applyDraftPort() {
        let requested = draftPort
        guard !isApplying, isDraftValid, requested != effectivePort else { return }
        isApplying = true
        Task {
            let result = await hostActions.applyMobilePairingPort(requested)
            applyResult = result
            // Keep the field on the attempted value (with its warning) when the
            // port is in use; otherwise let it track the persisted value again.
            if case .portInUse = result {} else { editedPort = nil }
            isApplying = false
        }
    }

    /// Status under the port row: an out-of-range hint, the most recent Apply
    /// result for the cases the live indicator can't convey, or the live
    /// bound-port indicator otherwise.
    @ViewBuilder
    private var boundPortStatusRow: some View {
        if !isDraftValid {
            statusCaption {
                Label(
                    String(localized: "settings.mobile.port.status.invalid", defaultValue: "Port must be between 1 and 65535."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } else if case let .portInUse(requested) = applyResult {
            // The TCP listener is always running in tailscale mode, so the
            // "still listening on …" indicator is always accurate here.
            statusCaption {
                Label(
                    String(
                        localized: "settings.mobile.port.apply.inUse",
                        defaultValue: "Port \(requested) is in use. Still listening on \(status.current?.boundPort ?? requested)."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } else if let snapshot = status.current {
            statusCaption { boundPortStatusText(snapshot) }
        }
    }

    @ViewBuilder
    private func statusCaption(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .cmuxFont(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func boundPortStatusText(_ snapshot: MobilePairingStatusSnapshot) -> some View {
        if !snapshot.isRunning {
            Text(String(localized: "settings.mobile.port.status.starting", defaultValue: "Starting the pairing listener…"))
                .foregroundStyle(.secondary)
        } else if snapshot.usesEphemeralFallback, let bound = snapshot.boundPort {
            Label(
                String(
                    localized: "settings.mobile.port.status.fallback",
                    defaultValue: "Port \(snapshot.configuredPort) is in use. Listening on \(bound) instead."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else if let bound = snapshot.boundPort {
            Label(
                String(localized: "settings.mobile.port.status.ok", defaultValue: "Listening on port \(bound)."),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var displayNameRow: some View {
        // Show this Mac's system name as the placeholder so the user sees the
        // actual default that applies when the override is empty.
        let resolvedName = hostActions.mobilePairingDefaultDisplayName()
        let placeholder = resolvedName.isEmpty
            ? String(localized: "settings.mobile.displayName.placeholder", defaultValue: "This Mac's name")
            : resolvedName
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:iOSPairingDisplayName",
            String(localized: "settings.mobile.displayName", defaultValue: "Display Name"),
            subtitle: String(localized: "settings.mobile.displayName.subtitle", defaultValue: "Name the iOS app shows for this Mac when pairing. Empty uses this Mac's name."),
            controlWidth: Self.columnWidth
        ) {
            TextField(
                placeholder,
                text: Binding(get: { displayName.current }, set: { displayName.set($0) })
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("SettingsMobilePairingDisplayNameField")
        }
    }

    /// Read-only connection count and the reachable routes the phone can use.
    @ViewBuilder
    private var diagnostics: some View {
        let snapshot = status.current
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:connections",
            String(localized: "settings.mobile.connections", defaultValue: "Connected Devices"),
            subtitle: String(localized: "settings.mobile.connections.subtitle", defaultValue: "iOS devices currently attached to this Mac.")
        ) {
            Text("\(snapshot?.activeConnectionCount ?? 0)")
                .cmuxFont(size: 13, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        routesView(snapshot)
    }

    @ViewBuilder
    private func routesView(_ snapshot: MobilePairingStatusSnapshot?) -> some View {
        if let snapshot, snapshot.isRunning {
            if snapshot.routes.isEmpty {
                SettingsCardNote(String(
                    localized: "settings.mobile.routes.empty",
                    defaultValue: "No reachable addresses yet. Pairing over the network needs Tailscale running on this Mac."
                ))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "settings.mobile.routes.title", defaultValue: "Reachable at"))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(snapshot.routes) { route in
                        HStack(spacing: 8) {
                            Text(route.kindLabel)
                                .cmuxFont(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(route.endpoint)
                                .cmuxFont(.caption, design: .monospaced)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }
}
