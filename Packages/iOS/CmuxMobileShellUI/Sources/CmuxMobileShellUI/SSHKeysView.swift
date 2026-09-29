#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Lists this iPhone's SSH keys (PRD D3/D18): phone-generated Secure Enclave
/// keys and imported OpenSSH keys. Generate and Import push inside the same
/// navigation stack (HIG Sheets: one sheet at a time).
struct SSHKeysView: View {
    let computers: MobileSSHComputers
    @State private var pendingDeleteKeyID: UUID?
    @State private var deleteError: String?

    var body: some View {
        List {
            Section {
                if computers.keys.isEmpty {
                    Text(L10n.string(
                        "mobile.ssh.keys.empty",
                        defaultValue: "No keys yet. Generate a key on this iPhone or import one you already use."
                    ))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ssh.keys.empty")
                }
                ForEach(computers.keys) { key in
                    SSHKeyRow(
                        key: key,
                        requestDelete: { pendingDeleteKeyID = key.id }
                    )
                }
            } footer: {
                Text(L10n.string(
                    "mobile.ssh.keys.footer",
                    defaultValue: "Private keys never leave this iPhone. Share only the public key with a server."
                ))
            }
            Section {
                NavigationLink {
                    SSHGenerateKeyView(computers: computers, onCreated: { _ in })
                } label: {
                    Label(
                        L10n.string("mobile.ssh.keys.generate", defaultValue: "Generate New Key"),
                        systemImage: "key.fill"
                    )
                }
                .accessibilityIdentifier("ssh.keys.generate")
                NavigationLink {
                    SSHImportKeyView(computers: computers, onImported: { _ in })
                } label: {
                    Label(
                        L10n.string("mobile.ssh.keys.import", defaultValue: "Import Key"),
                        systemImage: "square.and.arrow.down"
                    )
                }
                .accessibilityIdentifier("ssh.keys.import")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(SSHCopy().keysTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ssh.keys")
        .alert(
            L10n.string("mobile.ssh.keys.delete.title", defaultValue: "Delete this key?"),
            isPresented: Binding(
                get: { pendingDeleteKeyID != nil },
                set: { if !$0 { pendingDeleteKeyID = nil } }
            ),
            presenting: pendingDeleteKeyID
        ) { keyID in
            Button(SSHCopy().delete, role: .destructive) {
                Task {
                    do {
                        try await computers.deleteKey(id: keyID)
                    } catch {
                        deleteError = String(describing: error)
                    }
                }
            }
            .accessibilityIdentifier("ssh.keys.delete.confirm")
            Button(SSHCopy().cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.string(
                "mobile.ssh.keys.delete.message",
                defaultValue: "Computers that use this key will need another key to log in. This can't be undone."
            ))
        }
        .alert(
            L10n.string("mobile.ssh.keys.delete.failed", defaultValue: "Couldn't delete the key"),
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
            presenting: deleteError
        ) { _ in
            Button(L10n.string("mobile.ssh.action.ok", defaultValue: "OK")) {}
        } message: { message in
            Text(message)
        }
    }
}

/// One key: its name, a metadata line (algorithm and origin, plus Face ID
/// when required), and its fingerprint, with copy / delete actions. Every
/// key states its origin so rows read the same. Value-only.
struct SSHKeyRow: View {
    let key: SSHKeyRecord
    let requestDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.label)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            SSHKeyMetadataLine(key: key)
            Text(key.fingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ssh.key.\(key.label)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: requestDelete) {
                Label(SSHCopy().delete, systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                UIPasteboard.general.string = key.publicKeyLine
            } label: {
                Label(SSHCopy().copy, systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = key.publicKeyLine
            } label: {
                Label(
                    L10n.string("mobile.ssh.keys.copyPublic", defaultValue: "Copy Public Key"),
                    systemImage: "doc.on.doc"
                )
            }
            ShareLink(item: key.publicKeyLine) {
                Label(
                    L10n.string("mobile.ssh.keys.sharePublic", defaultValue: "Share Public Key"),
                    systemImage: "square.and.arrow.up"
                )
            }
            Divider()
            Button(role: .destructive, action: requestDelete) {
                Label(SSHCopy().delete, systemImage: "trash")
            }
        }
    }
}

/// "ecdsa-sha2-nistp256 · [lock.shield] Secure Enclave": algorithm, then
/// where the key came from with a small inline symbol, all secondary. Built
/// as one `Text` so it wraps as a sentence instead of a row of badges.
struct SSHKeyMetadataLine: View {
    let key: SSHKeyRecord

    var body: some View {
        var line = Text(key.algorithm)
        for part in parts {
            line = line + Text(" · ") + Text(Image(systemName: part.symbol)) + Text(" ") + Text(part.text)
        }
        return line
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var parts: [(symbol: String, text: String)] {
        var parts: [(symbol: String, text: String)] = []
        switch key.kind {
        case .secureEnclave:
            parts.append(("lock.shield", L10n.string("mobile.ssh.keys.secureEnclave", defaultValue: "Secure Enclave")))
        case .imported:
            parts.append(("square.and.arrow.down", L10n.string("mobile.ssh.keys.imported", defaultValue: "Imported")))
        }
        if key.requiresBiometry {
            parts.append(("faceid", L10n.string("mobile.ssh.keys.faceID", defaultValue: "Face ID")))
        }
        return parts
    }
}

/// Creates a P-256 key in the Secure Enclave (PRD D3); Face ID per key,
/// default off (PRD D18).
struct SSHGenerateKeyView: View {
    let computers: MobileSSHComputers
    let onCreated: (SSHKeyRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Empty with a placeholder: pre-filling made typing append to the
    /// device name. An empty name falls back to ``defaultLabel``.
    @State private var label = ""
    @State private var requiresBiometry = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField(Self.defaultLabel, text: $label)
                    .sshLiteralTextEntry()
                    .accessibilityIdentifier("ssh.keys.generate.label")
            } header: {
                Text(L10n.string("mobile.ssh.keys.label", defaultValue: "Name"))
            }
            Section {
                Toggle(
                    L10n.string("mobile.ssh.keys.requireFaceID", defaultValue: "Require Face ID"),
                    isOn: $requiresBiometry
                )
                .accessibilityIdentifier("ssh.keys.generate.faceID")
            } footer: {
                Text(L10n.string(
                    "mobile.ssh.keys.generate.footer",
                    defaultValue: "The key is created in this iPhone's Secure Enclave and can never be exported. With Face ID on, every connection asks you to confirm, and sessions can't reconnect on their own in the background."
                ))
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("ssh.keys.generate.error")
                }
            }
        }
        .navigationTitle(L10n.string("mobile.ssh.keys.generate.title", defaultValue: "Generate Key"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button(L10n.string("mobile.ssh.keys.generate.create", defaultValue: "Create")) {
                        create()
                    }
                    .accessibilityIdentifier("ssh.keys.generate.create")
                }
            }
        }
    }

    static var defaultLabel: String {
        L10n.string("mobile.ssh.keys.generate.defaultLabel", defaultValue: "iPhone Key")
    }

    private var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultLabel : trimmed
    }

    private func create() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let record = try await computers.generateKey(label: resolvedLabel, requiresBiometry: requiresBiometry)
                onCreated(record)
                dismiss()
            } catch {
                errorMessage = SSHKeyErrorCopy().message(for: error)
            }
        }
    }
}

/// Imports an existing OpenSSH private key (pasted or from Files), with an
/// optional passphrase. Parse failures are explained in plain language.
struct SSHImportKeyView: View {
    let computers: MobileSSHComputers
    let onImported: (SSHKeyRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var keyText = ""
    @State private var passphrase = ""
    @State private var isShowingFileImporter = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField(
                    L10n.string("mobile.ssh.keys.label.placeholder", defaultValue: "Key name"),
                    text: $label
                )
                .sshLiteralTextEntry()
                .accessibilityIdentifier("ssh.keys.import.label")
            } header: {
                Text(L10n.string("mobile.ssh.keys.label", defaultValue: "Name"))
            }
            Section {
                TextEditor(text: $keyText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 140)
                    .sshLiteralTextEntry()
                    .accessibilityIdentifier("ssh.keys.import.text")
                Button {
                    isShowingFileImporter = true
                } label: {
                    Label(
                        L10n.string("mobile.ssh.keys.import.file", defaultValue: "Choose File…"),
                        systemImage: "folder"
                    )
                }
                .accessibilityIdentifier("ssh.keys.import.file")
            } header: {
                Text(L10n.string("mobile.ssh.keys.import.privateKey", defaultValue: "Private Key"))
            } footer: {
                Text(L10n.string(
                    "mobile.ssh.keys.import.footer",
                    defaultValue: "Paste the contents of a file like ~/.ssh/id_ed25519, starting with -----BEGIN OPENSSH PRIVATE KEY-----. Ed25519 and ECDSA keys are supported."
                ))
            }
            Section {
                SecureField(
                    L10n.string("mobile.ssh.keys.import.passphrase.placeholder", defaultValue: "Passphrase (if the key has one)"),
                    text: $passphrase
                )
                .textContentType(.password)
                .accessibilityIdentifier("ssh.keys.import.passphrase")
            } header: {
                Text(L10n.string("mobile.ssh.keys.import.passphrase", defaultValue: "Passphrase"))
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("ssh.keys.import.error")
                }
            }
        }
        .navigationTitle(L10n.string("mobile.ssh.keys.import.title", defaultValue: "Import Key"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button(L10n.string("mobile.ssh.keys.import.action", defaultValue: "Import")) {
                        importKey()
                    }
                    .disabled(trimmedKeyText.isEmpty)
                    .accessibilityIdentifier("ssh.keys.import.save")
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.data, .text, .item],
            allowsMultipleSelection: false
        ) { result in
            loadFile(result)
        }
    }

    private var trimmedKeyText: String {
        keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadFile(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Private keys are a few KB; refuse anything absurd so a wrong pick
        // cannot load a large file into a text view.
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1_024,
              let text = String(data: data, encoding: .utf8) else {
            errorMessage = SSHKeyErrorCopy().notAKey
            return
        }
        keyText = text
        if label.trimmingCharacters(in: .whitespaces).isEmpty {
            label = url.deletingPathExtension().lastPathComponent
        }
        errorMessage = nil
    }

    private func importKey() {
        isWorking = true
        errorMessage = nil
        let resolvedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmedKeyText
        let secret = passphrase.isEmpty ? nil : passphrase
        Task {
            defer { isWorking = false }
            do {
                let record = try await computers.importKey(
                    label: resolvedLabel.isEmpty
                        ? L10n.string("mobile.ssh.keys.import.defaultLabel", defaultValue: "Imported Key")
                        : resolvedLabel,
                    privateKeyText: text,
                    passphrase: secret
                )
                passphrase = ""
                onImported(record)
                dismiss()
            } catch {
                errorMessage = SSHKeyErrorCopy().message(for: error)
            }
        }
    }
}

/// Plain-language explanations for key parse and storage errors.
struct SSHKeyErrorCopy {
    var notAKey: String {
        L10n.string(
            "mobile.ssh.keys.error.notOpenSSH",
            defaultValue: "This isn't an OpenSSH private key. Choose the private key file (not the .pub file), which starts with -----BEGIN OPENSSH PRIVATE KEY-----."
        )
    }

    func message(for error: any Error) -> String {
        if let faceID = MobileSSHBiometryErrorCopy().message(for: error) {
            return faceID
        }
        switch error {
        case SSHPrivateKeyParseError.notOpenSSHFormat:
            return notAKey
        case SSHPrivateKeyParseError.passphraseRequired:
            return L10n.string(
                "mobile.ssh.keys.error.passphraseRequired",
                defaultValue: "This key is protected with a passphrase. Enter it below and try again."
            )
        case SSHPrivateKeyParseError.wrongPassphrase:
            return L10n.string(
                "mobile.ssh.keys.error.wrongPassphrase",
                defaultValue: "That passphrase doesn't unlock this key. Check it and try again."
            )
        case SSHPrivateKeyParseError.unsupportedCipher:
            return L10n.string(
                "mobile.ssh.keys.error.unsupportedCipher",
                defaultValue: "This key is encrypted in a format cmux doesn't support yet. Re-save it with ssh-keygen -p, then import again."
            )
        case SSHPrivateKeyParseError.unsupportedKeyType(let type):
            return String(
                format: L10n.string(
                    "mobile.ssh.keys.error.unsupportedKeyType",
                    defaultValue: "%@ keys aren't supported yet. Use an Ed25519 or ECDSA key, or generate a new key on this iPhone."
                ),
                type.isEmpty ? "RSA" : type
            )
        case SSHPrivateKeyParseError.malformed:
            return L10n.string(
                "mobile.ssh.keys.error.malformed",
                defaultValue: "This key looks damaged or incomplete. Copy the whole file, including the BEGIN and END lines."
            )
        case SSHKeyStoreError.secureEnclaveUnavailable:
            return L10n.string(
                "mobile.ssh.keys.error.secureEnclave",
                defaultValue: "This device can't create Secure Enclave keys. Import a key instead."
            )
        case SSHKeyStoreError.keychain, SSHKeyStoreError.missingSecret:
            return L10n.string(
                "mobile.ssh.keys.error.keychain",
                defaultValue: "The key couldn't be saved to the Keychain. Unlock your iPhone and try again."
            )
        default:
            return error.localizedDescription
        }
    }
}
#endif
