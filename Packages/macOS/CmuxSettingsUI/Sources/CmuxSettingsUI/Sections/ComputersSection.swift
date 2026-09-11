import CmuxSettings
import SwiftUI

public struct ComputersSection: View {
    private let actions: ComputersSettingsActions
    @State private var snapshot = ComputersSettingsSnapshot()
    @State private var pairingInput = ""
    @State private var pairingError: String?
    @State private var isPairing = false
    @State private var devices: DefaultsValueModel<Bool>
    @State private var devicesManagedByPolicy = ManagedDevicePolicy().isEnforced(.disableRemoteControl)

    public init(hostActions: SettingsHostActions, defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        actions = hostActions.computersSettingsActions()
        _devices = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.betaFeatures.devices))
    }

    public var body: some View {
        SettingsSectionHeader(
            String(localized: "settings.section.computers", defaultValue: "Computers"),
            section: .computers
        )
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(String(localized: "settings.betaFeatures.devices", defaultValue: "My Devices"), isOn: Binding(
                    get: { devices.current && !devicesManagedByPolicy },
                    set: {
                        guard !devicesManagedByPolicy else { return }
                        devices.set($0)
                        NotificationCenter.default.post(name: Notification.Name("rightSidebarBetaFeatureDidChange"), object: nil)
                    }
                ))
                .disabled(devicesManagedByPolicy)
                .accessibilityIdentifier("SettingsComputersEnabled")
                Text(String(localized: "settings.computers.optIn", defaultValue: "Manage discovery, incoming access, and hidden Macs in the Cloud right sidebar."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"), isOn: Binding(
                    get: { snapshot.discoveryEnabled },
                    set: { enabled in Task { await actions.setDiscoveryEnabled(enabled) } }
                ))
                .disabled(devicesManagedByPolicy || !devices.current)
                .accessibilityIdentifier("SettingsComputersDiscoveryToggle")
                Toggle(String(localized: "devices.incoming.toggle", defaultValue: "Allow access to this Mac"), isOn: Binding(
                    get: { snapshot.incomingAccessEnabled && !devicesManagedByPolicy },
                    set: { enabled in Task { await actions.setIncomingAccessEnabled(enabled) } }
                ))
                .disabled(devicesManagedByPolicy)
                .accessibilityIdentifier("SettingsComputersIncomingAccessToggle")
                Text(String(localized: "devices.incoming.help", defaultValue: "Make this Mac available to your other devices. Turning this off stops discovery and disconnects incoming Mac and iPhone sessions."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(String(localized: "settings.computers.description", defaultValue: "Your enabled Macs connect automatically through encrypted Iroh connections. No manual pairing is needed."))
                    Spacer()
                    Button(String(localized: "settings.computers.refresh", defaultValue: "Refresh")) {
                        Task { await actions.refresh() }
                    }
                }
                if !snapshot.isSignedIn {
                    Text(String(localized: "settings.computers.signIn", defaultValue: "Sign in to the same account on both Macs to discover and connect to them."))
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.computers) { computer in
                    ComputersSettingsRow(computer: computer, actions: actions, discoveryEnabled: snapshot.discoveryEnabled)
                }
                Divider()
                DisclosureGroup(String(localized: "devices.pairing.advanced", defaultValue: "Advanced: manual Tailscale pairing")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "settings.computers.pair.help", defaultValue: "On the other Mac, open Tailscale Pairing. Paste its pairing link or enter its numeric IP and port here. Both Macs must be connected to the same tailnet."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField(
                                String(localized: "settings.computers.pair.placeholder", defaultValue: "Pairing link or Tailscale IP:port"),
                                text: $pairingInput
                            )
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("SettingsComputersPairingInput")
                            .onSubmit { pair() }
                            Button(String(localized: "settings.computers.pair", defaultValue: "Pair Mac")) { pair() }
                                .disabled(devicesManagedByPolicy || !devices.current || !snapshot.isSignedIn || isPairing || pairingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("SettingsComputersPair")
                        }
                        if isPairing { ProgressView().controlSize(.small) }
                        if let error = pairingError ?? snapshot.error {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        Button(String(localized: "settings.computers.showPairing", defaultValue: "Show This Mac’s Pairing Details")) {
                            actions.showPairing()
                        }
                        .accessibilityIdentifier("SettingsComputersShowPairing")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(14)
        }
        .id("setting:computers:pair")
        .task {
            devices.startObserving()
            for await value in actions.updates() {
                guard !Task.isCancelled else { break }
                snapshot = value
            }
        }
        .task { await actions.refresh() }
        .task {
            for await _ in ManagedDevicePolicy.changeSignals() {
                devicesManagedByPolicy = ManagedDevicePolicy().isEnforced(.disableRemoteControl)
            }
        }
    }

    private func pair() {
        guard !devicesManagedByPolicy, devices.current, snapshot.isSignedIn, !isPairing, !pairingInput.isEmpty else { return }
        isPairing = true
        pairingError = nil
        Task {
            pairingError = await actions.pair(pairingInput)
            isPairing = false
        }
    }
}
