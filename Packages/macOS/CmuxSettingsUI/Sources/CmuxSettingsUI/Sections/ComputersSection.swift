import CmuxSettings
import SwiftUI

public struct ComputersSection: View {
    private let actions: ComputersSettingsActions
    @State private var snapshot = ComputersSettingsSnapshot()
    @State private var devices: DefaultsValueModel<Bool>
    @State private var discoveryManaged = ManagedDevicePolicy().isDeviceDiscoveryDisabled
    @State private var incomingAccessManaged = ManagedDevicePolicy().isIncomingDeviceAccessDisabled
    @State private var isRefreshing = false

    public init(hostActions: SettingsHostActions, defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        actions = hostActions.computersSettingsActions()
        _devices = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.devices))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(
                String(localized: "settings.section.computers", defaultValue: "Computers"),
                section: .computers
            )
            SettingsCard {
                SettingsCardRow(
                    String(localized: "settings.betaFeatures.devices", defaultValue: "My Devices"),
                    subtitle: String(localized: "settings.computers.optIn", defaultValue: "Show your other Macs and their workspaces in the sidebar.")
                ) {
                    Toggle(String(localized: "settings.betaFeatures.devices", defaultValue: "My Devices"), isOn: Binding(
                        get: { devices.current && !discoveryManaged },
                        set: {
                            guard !discoveryManaged else { return }
                            devices.set($0)
                            NotificationCenter.default.post(name: Notification.Name("rightSidebarBetaFeatureDidChange"), object: nil)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(discoveryManaged)
                    .accessibilityIdentifier("SettingsComputersEnabled")
                }
                SettingsCardDivider()
                preferenceRow(
                    title: String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"),
                    detail: String(localized: "devices.discovery.menuDetail", defaultValue: "Connect to Macs signed in to your account."),
                    enabled: snapshot.discoveryEnabled && devices.current,
                    managed: discoveryManaged,
                    disabled: !devices.current,
                    identifier: "SettingsComputersDiscoveryToggle",
                    set: { enabled in Task { await actions.setDiscoveryEnabled(enabled) } }
                )
            }
            Text(String(localized: "devices.thisMac", defaultValue: "This Mac"))
                .font(.headline)
            SettingsCard {
                preferenceRow(
                    title: String(localized: "devices.incoming.toggle", defaultValue: "Allow access to this Mac"),
                    detail: String(localized: "devices.incoming.menuDetail", defaultValue: "Let your other Macs and iPhone connect here."),
                    enabled: snapshot.incomingAccessEnabled,
                    managed: incomingAccessManaged,
                    identifier: "SettingsComputersIncomingAccessToggle",
                    set: { enabled in Task { await actions.setIncomingAccessEnabled(enabled) } }
                )
                SettingsCardNote(String(localized: "devices.incoming.help", defaultValue: "Turning this off removes this Mac from discovery and disconnects incoming sessions. You can still connect to your other Macs."))
            }
            HStack {
                Text(String(localized: "devices.yourMacs", defaultValue: "Your Macs"))
                    .font(.headline)
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                Button(String(localized: "settings.computers.refresh", defaultValue: "Refresh")) {
                    Task { await refresh() }
                }
                .disabled(isRefreshing || !snapshot.isSignedIn || !discoveryEnabled)
                .accessibilityIdentifier("SettingsComputersRefresh")
            }
            SettingsCard {
                if !snapshot.isSignedIn {
                    SettingsCardNote(String(localized: "settings.computers.signIn", defaultValue: "Sign in to the same account on both Macs to discover and connect to them."))
                } else if !discoveryEnabled {
                    SettingsCardNote(String(localized: "devices.discovery.settingsDisabled", defaultValue: "Turn on My Devices and discovery to find your other Macs."))
                } else if snapshot.computers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(String(localized: "devices.empty.title", defaultValue: "No other Macs yet"), systemImage: "desktopcomputer")
                            .font(.callout.weight(.medium))
                        Text(String(localized: "devices.empty.help", defaultValue: "Sign in to cmux on another Mac and turn on Allow access to this Mac in Computers settings."))
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
            Text(String(localized: "devices.visibility.help", defaultValue: "Hiding a Mac only removes it from this sidebar. To stop access to a Mac, turn off Allow access to this Mac on that computer."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .id("setting:computers:pair")
        .task {
            devices.startObserving()
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
        devices.current && snapshot.discoveryEnabled && !discoveryManaged
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await actions.refresh()
    }

    private func preferenceRow(
        title: String, detail: String, enabled: Bool, managed: Bool,
        disabled: Bool = false, identifier: String, set: @escaping (Bool) -> Void
    ) -> some View {
        SettingsCardRow(title, subtitle: managed
            ? String(localized: "devices.managed", defaultValue: "Disabled by your administrator.")
            : detail
        ) {
            Toggle(title, isOn: Binding(get: { enabled && !managed }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(managed || disabled)
                .accessibilityIdentifier(identifier)
        }
    }
}
