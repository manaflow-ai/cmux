import AppKit
import Bonsplit
import SwiftUI

// MARK: - Editor Sheet

struct ProviderAccountEditorSheet: View {
    let provider: UsageProvider
    let editingAccount: ProviderAccount?
    let onDismiss: () -> Void

    @State private var displayName: String = ""
    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isSaving: Bool = false
    @State private var isLoadingCredentials: Bool = false

    private var isEditing: Bool { editingAccount != nil }

    private var isValid: Bool {
        let nameOk = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A provider with no credential fields cannot produce a meaningful
        // ProviderSecret — reject save rather than persisting an empty payload.
        guard !provider.credentialFields.isEmpty else { return false }
        let fieldsOk = provider.credentialFields.allSatisfy { field in
            let value = values[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let validate = field.validate {
                return validate(value)
            }
            return !value.isEmpty
        }
        return nameOk && fieldsOk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(isEditing
                    ? String(
                        localized: "providers.accounts.editor.title.edit",
                        defaultValue: "Edit \(provider.displayName) account"
                    )
                    : String(
                        localized: "providers.accounts.editor.title.add",
                        defaultValue: "Add \(provider.displayName) account"
                    )
                )
                .font(.headline)

                Spacer()

                if let helpDocURL = provider.helpDocURL {
                    Button {
                        NSWorkspace.shared.open(helpDocURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                            Text(String(
                                localized: "providers.accounts.help.link",
                                defaultValue: "Setup instructions"
                            ))
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    let nameLabel = String(
                        localized: "providers.accounts.editor.name",
                        defaultValue: "Display name"
                    )
                    Text(nameLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(nameLabel)
                }

                ForEach(provider.credentialFields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Credential inputs are locked while the existing
                        // secret is being read back from Keychain so an async
                        // load completion can't clobber characters the user
                        // started typing.
                        if field.isSecret {
                            SecureField(field.placeholder, text: fieldBinding(for: field.id))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(field.label)
                                .disabled(isLoadingCredentials)
                        } else {
                            TextField(field.placeholder, text: fieldBinding(for: field.id))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(field.label)
                                .disabled(isLoadingCredentials)
                        }
                        if let helpText = field.helpText {
                            Text(helpText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                // Cancel is locked while a save is in flight so the user
                // can't dismiss the sheet halfway through a keychain write
                // and be surprised by credentials still landing on disk.
                Button(String(localized: "providers.accounts.editor.cancel", defaultValue: "Cancel")) {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button(String(localized: "providers.accounts.editor.save", defaultValue: "Save")) {
                    guard !isSaving else { return }
                    isSaving = true
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task {
            guard let account = editingAccount else { return }
            displayName = account.displayName
            isLoadingCredentials = true
            defer { isLoadingCredentials = false }
            do {
                let secret = try await ProviderAccountStore.shared.secret(for: account.id)
                for field in provider.credentialFields {
                    values[field.id] = secret.fields[field.id] ?? ""
                }
            } catch let storeError as ProviderAccountStoreError {
                errorMessage = storeError.localizedDescription
            } catch {
                errorMessage = String(
                    localized: "providers.accounts.error.loadSecret",
                    defaultValue: "Could not load saved credentials. Re-enter them to save changes."
                )
            }
        }
    }

    private func fieldBinding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func save() async {
        errorMessage = nil

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedFields: [String: String] = [:]
        for field in provider.credentialFields {
            let trimmed = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                trimmedFields[field.id] = trimmed
            }
        }

        let secret = ProviderSecret(fields: trimmedFields)

        do {
            if let account = editingAccount {
                try await ProviderAccountStore.shared.update(id: account.id, displayName: trimmedName, secret: secret)
            } else {
                try await ProviderAccountStore.shared.add(
                    providerId: provider.id,
                    displayName: trimmedName,
                    secret: secret
                )
            }
            ProviderAccountsController.shared.refreshNow()
            onDismiss()
        } catch let storeError as ProviderAccountStoreError {
            errorMessage = storeError.localizedDescription
            isSaving = false
        } catch {
            // An unexpected error type reached here; show a purely localized
            // message so raw OS-level strings never leak into the sheet.
            #if DEBUG
            dlog("ProviderAccountEditorSheet: save failed")
            #endif
            errorMessage = String(
                localized: "providers.accounts.error.saveFailed",
                defaultValue: "Could not save credentials. Please try again."
            )
            isSaving = false
        }
    }
}
