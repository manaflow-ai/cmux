import CmuxSettings
import SwiftUI

/// **Devices** section under Remote & Devices: the settings home of the
/// Cloud sidebar's My Devices. Holds the two independent switches (make
/// this Mac discoverable, discover other Macs) and the account's other
/// Macs, with pairing, visibility, and open actions per row.
///
/// The switches write the same ``DevicesPreferencesModel`` the sidebar's
/// ``ComputerAccessMenuItems`` menu does, so either surface reflects a
/// change made in the other.
public struct ComputersSection: View {
    private let actions: ComputersSettingsActions
    @State private var snapshot = ComputersSettingsSnapshot()
    @State private var discoveryManaged = ManagedDevicePolicy().isDeviceDiscoveryDisabled
    @State private var incomingAccessManaged = ManagedDevicePolicy().isIncomingDeviceAccessDisabled
    @State private var isRefreshing = false

    public init(hostActions: SettingsHostActions, defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        actions = hostActions.computersSettingsActions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(String(localized: "settings.section.devices", defaultValue: "Devices"), section: .computers)
            SettingsCard {
                DevicesAccessToggleRow(
                    searchAnchorID: "setting:computers:incoming-access",
                    title: String(localized: "devices.incoming.toggle", defaultValue: "Make this Mac discoverable"),
                    help: String(localized: "devices.incoming.help", defaultValue: "Turning this off removes this Mac from discovery and disconnects incoming sessions. You can still connect to your other Macs."),
                    isOn: snapshot.incomingAccessEnabled,
                    managed: incomingAccessManaged,
                    unavailable: snapshot.unavailableMessage != nil,
                    identifier: "SettingsComputersIncomingAccessToggle",
                    set: { enabled in Task { await actions.setIncomingAccessEnabled(enabled) } }
                )
                SettingsCardDivider()
                DevicesAccessToggleRow(
                    searchAnchorID: "setting:computers:discovery",
                    title: String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"),
                    help: String(localized: "devices.discovery.help", defaultValue: "Find and connect to other Macs signed in to your account. Turning this off disconnects their panes without closing their terminals."),
                    isOn: snapshot.discoveryEnabled,
                    managed: discoveryManaged,
                    unavailable: snapshot.unavailableMessage != nil,
                    identifier: "SettingsComputersDiscoveryToggle",
                    set: { enabled in Task { await actions.setDiscoveryEnabled(enabled) } }
                )
            }
            HStack {
                Text(String(localized: "devices.yourMacs", defaultValue: "Your Macs"))
                    .font(.headline)
                    .accessibilityIdentifier("SettingsComputersHeading")
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                Button(String(localized: "settings.computers.refresh", defaultValue: "Refresh")) {
                    Task { await refresh() }
                }
                .disabled(isRefreshing || snapshot.unavailableMessage != nil || !snapshot.isSignedIn || !discoveryEnabled)
                .accessibilityIdentifier("SettingsComputersRefresh")
            }
            SettingsCard {
                if let unavailable = snapshot.unavailableMessage {
                    SettingsCardNote(unavailable)
                } else if !snapshot.isSignedIn {
                    SettingsCardNote(String(localized: "settings.computers.signIn", defaultValue: "Sign in to the same account on both Macs to discover and connect to them."))
                } else if discoveryManaged {
                    SettingsCardNote(String(localized: "devices.managed", defaultValue: "Disabled by your administrator."))
                } else if !discoveryEnabled {
                    SettingsCardNote(String(localized: "devices.discovery.settingsDisabled", defaultValue: "Turn on Discover other Macs to see your devices."))
                } else if snapshot.computers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(String(localized: "devices.empty.title", defaultValue: "No other Macs yet"), systemImage: "desktopcomputer")
                            .font(.callout.weight(.medium))
                        Text(String(localized: "devices.empty.help", defaultValue: "Sign in to cmux on another Mac and make it discoverable in Settings › Devices."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                } else {
                    ForEach(snapshot.computers) { computer in
                        ComputersSettingsRow(computer: computer, actions: actions, discoveryEnabled: discoveryEnabled)
                        if computer.id != snapshot.computers.last?.id { SettingsCardDivider() }
                    }
                }
            }
            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task {
            for await value in actions.updates() {
                guard !Task.isCancelled else { break }
                snapshot = value
            }
        }
        .task { await refresh() }
        .task {
            for await _ in ManagedDevicePolicy.changeSignals() {
                let policy = ManagedDevicePolicy()
                discoveryManaged = policy.isDeviceDiscoveryDisabled
                incomingAccessManaged = policy.isIncomingDeviceAccessDisabled
            }
        }
    }

    private var discoveryEnabled: Bool {
        snapshot.discoveryEnabled && !discoveryManaged
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await actions.refresh()
    }
}
