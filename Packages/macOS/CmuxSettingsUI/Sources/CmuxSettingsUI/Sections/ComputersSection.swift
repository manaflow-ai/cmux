import CmuxSettings
import SwiftUI

public struct ComputersSection: View {
    private let actions: ComputersSettingsActions
    @State private var snapshot = ComputersSettingsSnapshot()
    @State private var devices: DefaultsValueModel<Bool>
    @State private var discoveryManaged = ManagedDevicePolicy().isDeviceDiscoveryDisabled
    @State private var incomingAccessManaged = ManagedDevicePolicy().isIncomingDeviceAccessDisabled
    /// The My Devices beta itself is locked only by the remote-control ban, the
    /// same rule Beta Features applies. An independent discovery policy locks
    /// the discovery toggle below, not this switch.
    @State private var devicesManaged = ManagedDevicePolicy().isEnforced(.disableRemoteControl)
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
                optionsMenu
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
                devicesManaged = policy.isEnforced(.disableRemoteControl)
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

    private var optionsMenu: some View {
        Menu {
            Toggle(String(localized: "settings.betaFeatures.devices", defaultValue: "My Devices"), isOn: Binding(
                get: { devices.current && !devicesManaged },
                set: {
                    guard !devicesManaged else { return }
                    devices.set($0)
                    NotificationCenter.default.post(name: Notification.Name("rightSidebarBetaFeatureDidChange"), object: nil)
                }
            ))
            .disabled(devicesManaged)
            .help(String(localized: "settings.computers.optIn", defaultValue: "Show your other Macs and their workspaces in the sidebar."))
            .accessibilityIdentifier("SettingsComputersEnabled")
            Divider()
            ComputerAccessMenuItems(
                discoveryEnabled: snapshot.discoveryEnabled,
                incomingAccessEnabled: snapshot.incomingAccessEnabled,
                discoveryManaged: discoveryManaged,
                incomingAccessManaged: incomingAccessManaged,
                discoveryAvailable: devices.current,
                identifierPrefix: "SettingsComputers",
                setDiscovery: { enabled in Task { await actions.setDiscoveryEnabled(enabled) } },
                setIncomingAccess: { enabled in Task { await actions.setIncomingAccessEnabled(enabled) } }
            )
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "devices.manage", defaultValue: "Manage My Devices"))
        .accessibilityLabel(String(localized: "devices.manage", defaultValue: "Manage My Devices"))
        .accessibilityIdentifier("SettingsComputersOptions")
    }
}
