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
                    get: { devices.current },
                    set: {
                        guard !devicesManagedByPolicy else { return }
                        devices.set($0)
                        NotificationCenter.default.post(name: Notification.Name("rightSidebarBetaFeatureDidChange"), object: nil)
                    }
                ))
                .disabled(devicesManagedByPolicy)
                .accessibilityIdentifier("SettingsComputersEnabled")
                Text(String(localized: "settings.computers.optIn", defaultValue: "Enables viewing your paired Macs and makes this Mac available to other devices signed in to your account."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(String(localized: "settings.computers.description", defaultValue: "View and control your other Macs over Tailscale."))
                    Spacer()
                    Button(String(localized: "settings.computers.refresh", defaultValue: "Refresh")) {
                        Task { await actions.refresh() }
                    }
                }
                if !snapshot.isSignedIn {
                    Text(String(localized: "settings.computers.signIn", defaultValue: "Sign in to the same account on both Macs to pair them."))
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.computers) { computer in
                    ComputersSettingsRow(computer: computer, actions: actions)
                }
                Divider()
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
                        .disabled(!devices.current || !snapshot.isSignedIn || isPairing || pairingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        guard devices.current, snapshot.isSignedIn, !isPairing, !pairingInput.isEmpty else { return }
        isPairing = true
        pairingError = nil
        Task {
            pairingError = await actions.pair(pairingInput)
            isPairing = false
        }
    }
}
