import CmuxSettings
import SwiftUI

/// **Mobile** section — Mac-side controls for pairing and syncing with
/// cmux on iOS: the pairing-host toggle, the preferred listener port (with a
/// live bound-port indicator), an optional display-name override, and
/// connection/route diagnostics.
@MainActor
public struct MobileSection: View {
    @State private var iOSPairingHost: DefaultsValueModel<Bool>
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
    /// Guards against overlapping Apply taps while a probe is in flight.
    @State private var isApplying = false

    /// The Mac's system name, used as the display-name placeholder when no
    /// override is set. Captured once from the host; it does not change during a
    /// settings session, so it never goes stale as the override is edited.
    private let defaultDisplayName: String

    /// Applies a requested port through the host (availability-checked). Captured
    /// as a closure so the section holds no reference to the host bridge.
    private let applyPort: (Int) async -> MobilePairingPortApplyResult

    private static let columnWidth: CGFloat = 196

    /// Creates a Mobile settings section bound to the supplied settings stores.
    ///
    /// - Parameters:
    ///   - defaultsStore: UserDefaults-backed store for the pairing settings.
    ///   - catalog: The settings catalog providing the Mobile keys.
    ///   - hostActions: Host bridge that supplies the live pairing status used
    ///     by the bound-port indicator and diagnostics.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        let portModel = DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingPort)
        _iOSPairingHost = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingHost))
        _port = State(initialValue: portModel)
        _displayName = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.mobile.iOSPairingDisplayName))
        _status = State(initialValue: MobilePairingStatusModel(hostActions: hostActions))
        defaultDisplayName = hostActions.mobilePairingDefaultDisplayName()
        applyPort = { await hostActions.applyMobilePairingPort($0) }
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

    /// The Mobile settings section content.
    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.mobile", defaultValue: "Mobile"), section: .mobile)
            SettingsCard {
                iOSPairingHostRow
                SettingsCardDivider()
                portRow
                boundPortStatusRow
                SettingsCardDivider()
                displayNameRow
                if iOSPairingHost.current {
                    SettingsCardDivider()
                    diagnostics
                }
                SettingsCardNote(String(
                    localized: "settings.mobile.port.note",
                    defaultValue: "Click Apply to change the port. cmux checks the port is free first: if it's in use, the current listener keeps running untouched; if it's free, it rebinds and connected devices reconnect on the new port."
                ))
            }
        }
    }

    @ViewBuilder
    private var iOSPairingHostRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:mobile:iOSPairingHost",
            String(localized: "settings.mobile.iOSPairingHost", defaultValue: "iOS Pairing"),
            subtitle: iOSPairingHost.current
                ? String(localized: "settings.mobile.iOSPairingHost.subtitleOn", defaultValue: "Allows the iOS app to discover and sync with this Mac on your local network.")
                : String(localized: "settings.mobile.iOSPairingHost.subtitleOff", defaultValue: "Keeps the Mac-side iOS pairing listener off until you enable it here.")
        ) {
            Toggle("", isOn: Binding(get: { iOSPairingHost.current }, set: { iOSPairingHost.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMobileIOSPairingHostToggle")
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
            let result = await applyPort(requested)
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
        } else if case let .savedForLater(saved) = applyResult {
            statusCaption {
                Label(
                    String(localized: "settings.mobile.port.apply.saved", defaultValue: "Saved. Will use port \(saved) when iOS Pairing is on."),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)
            }
        } else if iOSPairingHost.current, let snapshot = status.current {
            statusCaption { boundPortStatusText(snapshot) }
        }
    }

    @ViewBuilder
    private func statusCaption(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.caption)
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
        let placeholder = defaultDisplayName.isEmpty
            ? String(localized: "settings.mobile.displayName.placeholder", defaultValue: "This Mac's name")
            : defaultDisplayName
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
                .font(.system(size: 13, weight: .medium))
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(snapshot.routes) { route in
                        HStack(spacing: 8) {
                            Text(route.kindLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(route.endpoint)
                                .font(.caption.monospaced())
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
