#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

@MainActor
struct MobileIrohCustomPrivatePathEditor: View {
    private let existing: CmxIrohSettingsSnapshot.CustomPrivateNetwork?
    private let availableMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac]
    private let onSave: (CmxIrohCustomPrivatePathDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMacDeviceID: String
    @State private var addressesText: String
    @State private var isEnabled: Bool
    @State private var isSaving = false

    init(
        path: CmxIrohSettingsSnapshot.CustomPrivateNetwork?,
        availableMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac],
        onSave: @escaping (CmxIrohCustomPrivatePathDraft) async -> Bool
    ) {
        existing = path
        self.availableMacs = availableMacs
        self.onSave = onSave
        _selectedMacDeviceID = State(
            initialValue: path?.macDeviceID ?? availableMacs.first?.id ?? ""
        )
        _addressesText = State(initialValue: path?.addresses.joined(separator: "\n") ?? "")
        _isEnabled = State(initialValue: path?.isEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let existing {
                        LabeledContent(
                            L10n.string(
                                "mobile.iroh.private.custom.mac",
                                defaultValue: "Mac"
                            ),
                            value: displayName(existing.macDisplayName)
                        )
                    } else {
                        Picker(
                            L10n.string(
                                "mobile.iroh.private.custom.mac",
                                defaultValue: "Mac"
                            ),
                            selection: $selectedMacDeviceID
                        ) {
                            ForEach(availableMacs) { mac in
                                Text(displayName(mac.displayName))
                                    .tag(mac.id)
                            }
                        }
                    }
                }

                Section {
                    TextEditor(text: $addressesText)
                        .frame(minHeight: 110)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("MobileIrohCustomPrivateAddresses")
                    Toggle(
                        L10n.string(
                            "mobile.iroh.private.custom.enabled",
                            defaultValue: "Use These Addresses"
                        ),
                        isOn: $isEnabled
                    )
                } header: {
                    Text(L10n.string(
                        "mobile.iroh.private.custom.addresses",
                        defaultValue: "Numeric IP Addresses"
                    ))
                } footer: {
                    Text(L10n.string(
                        "mobile.iroh.private.custom.addresses.footer",
                        defaultValue: "Enter one IPv4 or IPv6 address per line, without a port. cmux combines it with the Mac's current broker-authenticated Iroh UDP port."
                    ))
                }
            }
            .navigationTitle(existing == nil
                ? L10n.string(
                    "mobile.iroh.private.custom.add",
                    defaultValue: "Add Private Addresses"
                )
                : L10n.string(
                    "mobile.iroh.private.custom.edit",
                    defaultValue: "Edit Private Addresses"
                ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        save()
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
    }

    private var addresses: [String] {
        addressesText
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isValid: Bool {
        !selectedMacDeviceID.isEmpty
            && !addresses.isEmpty
            && addresses.count <= 8
            && addresses.allSatisfy { (try? CmxIrohCustomPrivateAddress($0)) != nil }
    }

    private func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return L10n.string("mobile.iroh.private.custom.unnamedMac", defaultValue: "Mac")
    }

    private func save() {
        guard isValid, !isSaving else { return }
        let mac = availableMacs.first { $0.id == selectedMacDeviceID }
        let displayName = existing?.macDisplayName ?? mac?.displayName ?? ""
        let draft = CmxIrohCustomPrivatePathDraft(
            macDeviceID: selectedMacDeviceID,
            macDisplayName: displayName,
            addresses: addresses,
            isEnabled: isEnabled
        )
        isSaving = true
        Task {
            if await onSave(draft) { dismiss() }
            isSaving = false
        }
    }
}
#endif
