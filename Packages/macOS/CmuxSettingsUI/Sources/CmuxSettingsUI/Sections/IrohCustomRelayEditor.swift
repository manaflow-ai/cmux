import CMUXMobileCore
import SwiftUI

/// Sheet for creating or editing one account-visible custom relay.
@MainActor
struct IrohCustomRelayEditor: View {
    private let existingID: String?
    private let onSave: (CmxIrohCustomRelayDraft, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var provider: String
    @State private var region: String
    @State private var url: String
    @State private var authMode: CmxIrohCustomRelayCredentialMode
    @State private var deviceSecret = ""
    @State private var isSaving = false

    init(
        relay: CmxIrohSettingsSnapshot.CustomRelay?,
        onSave: @escaping (CmxIrohCustomRelayDraft, String?) async -> Bool
    ) {
        existingID = relay?.id
        self.onSave = onSave
        _displayName = State(initialValue: relay?.displayName ?? "")
        _provider = State(initialValue: relay?.provider ?? "")
        _region = State(initialValue: relay?.region ?? "")
        _url = State(initialValue: relay?.url ?? "https://")
        _authMode = State(initialValue: relay?.authMode ?? .none)
    }

    var body: some View {
        Form {
            TextField(
                String(localized: "settings.networking.custom.name", defaultValue: "Name"),
                text: $displayName
            )
            TextField(
                String(localized: "settings.networking.custom.provider", defaultValue: "Provider"),
                text: $provider
            )
            TextField(
                String(localized: "settings.networking.custom.region", defaultValue: "Region"),
                text: $region
            )
            TextField(
                String(localized: "settings.networking.custom.url", defaultValue: "Relay URL"),
                text: $url
            )
            Picker(
                String(localized: "settings.networking.custom.authentication", defaultValue: "Authentication"),
                selection: $authMode
            ) {
                Text(String(localized: "settings.networking.custom.authentication.none", defaultValue: "None"))
                    .tag(CmxIrohCustomRelayCredentialMode.none)
                Text(String(localized: "settings.networking.custom.authentication.secret", defaultValue: "Device Secret"))
                    .tag(CmxIrohCustomRelayCredentialMode.deviceSecret)
            }
            if authMode == .deviceSecret {
                SecureField(
                    existingID == nil
                        ? String(localized: "settings.networking.custom.secret", defaultValue: "Relay Secret")
                        : String(localized: "settings.networking.custom.secret.keep", defaultValue: "New Secret (leave blank to keep current)"),
                    text: $deviceSecret
                )
                Text(String(
                    localized: "settings.networking.custom.secret.note",
                    defaultValue: "The secret stays in this device's secure storage and never syncs with your account."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 390)
        .navigationTitle(existingID == nil
            ? String(localized: "settings.networking.custom.add", defaultValue: "Add Custom Relay")
            : String(localized: "settings.networking.custom.edit", defaultValue: "Edit Custom Relay"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "settings.common.cancel", defaultValue: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "settings.common.save", defaultValue: "Save")) { save() }
                    .disabled(!isValid || isSaving)
            }
        }
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && url.hasPrefix("https://")
            && (authMode == .none || existingID != nil || !deviceSecret.isEmpty)
    }

    private func save() {
        guard isValid, !isSaving else { return }
        isSaving = true
        let draft = CmxIrohCustomRelayDraft(
            id: existingID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            authMode: authMode
        )
        let secret = deviceSecret.isEmpty ? nil : deviceSecret
        Task {
            if await onSave(draft, secret) { dismiss() }
            isSaving = false
        }
    }
}
