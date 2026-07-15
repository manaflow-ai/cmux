#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

@MainActor
struct MobileIrohCustomRelayEditor: View {
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
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.string("mobile.iroh.custom.name", defaultValue: "Name"), text: $displayName)
                    TextField(L10n.string("mobile.iroh.custom.provider", defaultValue: "Provider"), text: $provider)
                    TextField(L10n.string("mobile.iroh.custom.region", defaultValue: "Region"), text: $region)
                    TextField(L10n.string("mobile.iroh.custom.url", defaultValue: "Relay URL"), text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker(
                        L10n.string("mobile.iroh.custom.authentication", defaultValue: "Authentication"),
                        selection: $authMode
                    ) {
                        Text(L10n.string("mobile.iroh.custom.authentication.none", defaultValue: "None"))
                            .tag(CmxIrohCustomRelayCredentialMode.none)
                        Text(L10n.string("mobile.iroh.custom.authentication.secret", defaultValue: "Device Secret"))
                            .tag(CmxIrohCustomRelayCredentialMode.deviceSecret)
                    }
                    if authMode == .deviceSecret {
                        SecureField(
                            existingID == nil
                                ? L10n.string("mobile.iroh.custom.secret", defaultValue: "Relay Secret")
                                : L10n.string("mobile.iroh.custom.secret.keep", defaultValue: "New Secret (optional)"),
                            text: $deviceSecret
                        )
                    }
                } footer: {
                    Text(L10n.string(
                        "mobile.iroh.custom.secret.note",
                        defaultValue: "Relay secrets stay in this device's Keychain and do not sync with your account."
                    ))
                }
            }
            .navigationTitle(existingID == nil
                ? L10n.string("mobile.iroh.custom.add", defaultValue: "Add Custom Relay")
                : L10n.string("mobile.iroh.custom.edit", defaultValue: "Edit Custom Relay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) { save() }
                        .disabled(!isValid || isSaving)
                }
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
        Task {
            if await onSave(draft, deviceSecret.isEmpty ? nil : deviceSecret) { dismiss() }
            isSaving = false
        }
    }
}
#endif
