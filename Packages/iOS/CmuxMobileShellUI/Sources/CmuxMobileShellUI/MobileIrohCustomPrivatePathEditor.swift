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
    @State private var validation: Validation

    struct Validation: Equatable {
        let addresses: [String]
        let canSave: Bool
    }

    init(
        path: CmxIrohSettingsSnapshot.CustomPrivateNetwork?,
        availableMacs: [CmxIrohSettingsSnapshot.PrivateNetworkMac],
        onSave: @escaping (CmxIrohCustomPrivatePathDraft) async -> Bool
    ) {
        existing = path
        self.availableMacs = availableMacs
        self.onSave = onSave
        let selectedMacDeviceID = path?.macDeviceID ?? availableMacs.first?.id ?? ""
        let addressesText = path?.addresses.joined(separator: "\n") ?? ""
        _selectedMacDeviceID = State(initialValue: selectedMacDeviceID)
        _addressesText = State(initialValue: addressesText)
        _isEnabled = State(initialValue: path?.isEnabled ?? false)
        _validation = State(initialValue: Self.validate(
            addressesText: addressesText,
            selectedMacDeviceID: selectedMacDeviceID
        ))
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
                    .disabled(!validation.canSave || isSaving)
                }
            }
            .onChange(of: addressesText) { _, _ in refreshValidation() }
            .onChange(of: selectedMacDeviceID) { _, _ in refreshValidation() }
        }
    }

    static func validate(
        addressesText: String,
        selectedMacDeviceID: String
    ) -> Validation {
        let addresses = addressesText
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let canSave = !selectedMacDeviceID.isEmpty
            && !addresses.isEmpty
            && addresses.count <= CmxIrohCustomPrivatePathDraft.maximumAddressCount
            && addresses.allSatisfy { (try? CmxIrohCustomPrivateAddress($0)) != nil }
        return Validation(addresses: addresses, canSave: canSave)
    }

    private func refreshValidation() {
        validation = Self.validate(
            addressesText: addressesText,
            selectedMacDeviceID: selectedMacDeviceID
        )
    }

    private func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return L10n.string("mobile.iroh.private.custom.unnamedMac", defaultValue: "Mac")
    }

    private func save() {
        guard validation.canSave, !isSaving else { return }
        let mac = availableMacs.first { $0.id == selectedMacDeviceID }
        let displayName = existing?.macDisplayName ?? mac?.displayName ?? ""
        let draft = CmxIrohCustomPrivatePathDraft(
            macDeviceID: selectedMacDeviceID,
            macDisplayName: displayName,
            addresses: validation.addresses,
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
