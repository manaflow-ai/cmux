#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
import UIKit

/// The editable fields of an SSH computer. Validated here so the form, its
/// Save button, and the password install share one rule.
struct SSHComputerDraft: Equatable {
    var name = ""
    var host = ""
    var port = "22"
    var username = ""
    var keyID: UUID?
    var jumpHostID: UUID?
    var persistence: SSHPersistenceMode?
    var idleClose: SSHIdleClosePolicy = .oneDay

    init() {}

    init(record: SSHHostRecord) {
        name = record.name
        host = record.endpoint.host
        port = String(record.endpoint.port)
        username = record.endpoint.username
        keyID = record.keyID
        jumpHostID = record.jumpHostID
        persistence = record.persistence
        idleClose = record.idleClose
    }

    var trimmedHost: String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept a pasted bracketed IPv6 literal.
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    /// The first problem, in field order, or `nil` when the draft can be saved.
    var validationMessage: String? {
        if trimmedHost.isEmpty || trimmedHost.contains(where: \.isWhitespace) {
            return L10n.string("mobile.ssh.form.error.host", defaultValue: "Enter the computer's address, like 192.168.1.20 or server.example.com.")
        }
        if portNumber == nil {
            return L10n.string("mobile.ssh.form.error.port", defaultValue: "Port must be a number from 1 to 65535.")
        }
        if trimmedUsername.isEmpty {
            return L10n.string("mobile.ssh.form.error.username", defaultValue: "Enter the username you log in with.")
        }
        return nil
    }

    func record(id: UUID, existing: SSHHostRecord?) -> SSHHostRecord? {
        guard validationMessage == nil, let portNumber else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var record = existing ?? SSHHostRecord(
            id: id,
            name: trimmedName,
            endpoint: SSHEndpoint(host: trimmedHost, port: portNumber, username: trimmedUsername)
        )
        record.name = trimmedName.isEmpty ? trimmedHost : trimmedName
        record.endpoint = SSHEndpoint(host: trimmedHost, port: portNumber, username: trimmedUsername)
        record.keyID = keyID
        record.jumpHostID = jumpHostID == id ? nil : jumpHostID
        record.persistence = persistence
        record.idleClose = idleClose
        return record
    }
}

/// Add or edit an SSH computer (PRD D2/D3/D9/D13/D16). Presented as a root
/// sheet (Cancel/Save) or pushed inside the Computers sheet (Save only).
struct SSHComputerEditorView: View {
    let computers: MobileSSHComputers
    let showsCancel: Bool
    /// Called after Save (with the host id), Delete (`nil`), or Cancel (`nil`).
    let onFinish: (UUID?) -> Void

    private let existing: SSHHostRecord?
    private let initialDraft: SSHComputerDraft
    @State private var hostID: UUID
    @State private var draft: SSHComputerDraft
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isAskingPassword = false
    @State private var password = ""
    @State private var installState: InstallState = .idle
    @State private var isConfirmingDelete = false
    @State private var showsValidation = false

    private enum InstallState: Equatable {
        case idle
        case installing
        case succeeded
        case failed(String)
    }

    init(
        computers: MobileSSHComputers,
        existing: SSHHostRecord?,
        showsCancel: Bool,
        onFinish: @escaping (UUID?) -> Void
    ) {
        self.computers = computers
        self.existing = existing
        self.showsCancel = showsCancel
        self.onFinish = onFinish
        var draft = existing.map(SSHComputerDraft.init(record:)) ?? SSHComputerDraft()
        if existing == nil, draft.keyID == nil {
            draft.keyID = computers.keys.first?.id
        }
        initialDraft = draft
        _draft = State(initialValue: draft)
        _hostID = State(initialValue: existing?.id ?? UUID())
    }

    private var isDirty: Bool { draft != initialDraft }

    private var selectedKey: SSHKeyRecord? {
        draft.keyID.flatMap { id in computers.keys.first { $0.id == id } }
    }

    private var jumpCandidates: [SSHHostRecord] {
        computers.hosts.filter { $0.id != hostID }
    }

    var body: some View {
        Form {
            connectionSection
            keySection
            if let selectedKey {
                installSection(key: selectedKey)
            }
            sessionSection
            idleSection
            jumpSection
            if let saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("ssh.form.error")
                }
            }
            if existing != nil {
                Section {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label(
                            L10n.string("mobile.ssh.form.delete", defaultValue: "Delete Computer"),
                            systemImage: "trash"
                        )
                    }
                    .accessibilityIdentifier("ssh.form.delete")
                }
            }
        }
        .navigationTitle(existing == nil
            ? SSHCopy.addComputer
            : L10n.string("mobile.ssh.form.editTitle", defaultValue: "Edit SSH Computer"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(showsCancel && isDirty)
        .accessibilityIdentifier("ssh.form")
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SSHCopy.cancel) { onFinish(nil) }
                        .accessibilityIdentifier("ssh.form.cancel")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(L10n.string("mobile.ssh.form.save", defaultValue: "Save")) {
                        Task { await saveAndFinish() }
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("ssh.form.save")
                }
            }
        }
        .alert(
            L10n.string("mobile.ssh.install.password.title", defaultValue: "Install Key with Password"),
            isPresented: $isAskingPassword
        ) {
            SecureField(
                L10n.string("mobile.ssh.install.password.placeholder", defaultValue: "Password"),
                text: $password
            )
            .textContentType(.password)
            .accessibilityIdentifier("ssh.install.password")
            Button(L10n.string("mobile.ssh.install.password.install", defaultValue: "Install")) {
                let secret = password
                password = ""
                Task { await install(password: secret) }
            }
            .accessibilityIdentifier("ssh.install.password.submit")
            Button(SSHCopy.cancel, role: .cancel) { password = "" }
        } message: {
            Text(String(
                format: L10n.string(
                    "mobile.ssh.install.password.message",
                    defaultValue: "Enter the password for %@ one time. cmux uses it to add this iPhone's public key to ~/.ssh/authorized_keys, then forgets it."
                ),
                "\(draft.trimmedUsername)@\(draft.trimmedHost)"
            ))
        }
        .alert(SSHCopy.deleteHostTitle, isPresented: $isConfirmingDelete) {
            Button(SSHCopy.delete, role: .destructive) {
                Task { await delete() }
            }
            .accessibilityIdentifier("ssh.form.delete.confirm")
            Button(SSHCopy.cancel, role: .cancel) {}
        } message: {
            Text(SSHCopy.deleteHostMessage)
        }
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section {
            LabeledContent(L10n.string("mobile.ssh.form.name", defaultValue: "Name")) {
                TextField(
                    L10n.string("mobile.ssh.form.name.placeholder", defaultValue: "Optional"),
                    text: $draft.name
                )
                .multilineTextAlignment(.trailing)
                .sshLiteralTextEntry()
                .accessibilityIdentifier("ssh.form.name")
            }
            LabeledContent(L10n.string("mobile.ssh.form.host", defaultValue: "Host")) {
                TextField(
                    L10n.string("mobile.ssh.form.host.placeholder", defaultValue: "Address or hostname"),
                    text: $draft.host
                )
                .multilineTextAlignment(.trailing)
                .keyboardType(.URL)
                .textContentType(.URL)
                .sshLiteralTextEntry()
                .accessibilityIdentifier("ssh.form.host")
            }
            LabeledContent(L10n.string("mobile.ssh.form.port", defaultValue: "Port")) {
                TextField("22", text: $draft.port)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .sshLiteralTextEntry()
                    .accessibilityIdentifier("ssh.form.port")
            }
            LabeledContent(L10n.string("mobile.ssh.form.username", defaultValue: "Username")) {
                TextField(
                    L10n.string("mobile.ssh.form.username.placeholder", defaultValue: "Required"),
                    text: $draft.username
                )
                .multilineTextAlignment(.trailing)
                .textContentType(.username)
                .sshLiteralTextEntry()
                .accessibilityIdentifier("ssh.form.username")
            }
        } header: {
            Text(L10n.string("mobile.ssh.form.connection", defaultValue: "Computer"))
        } footer: {
            if showsValidation, let message = draft.validationMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("ssh.form.validation")
            } else {
                Text(L10n.string(
                    "mobile.ssh.form.connection.footer",
                    defaultValue: "Any address this iPhone can reach: local network, Tailscale or another VPN, a public IP, or IPv6."
                ))
            }
        }
    }

    private var keySection: some View {
        Section {
            Picker(L10n.string("mobile.ssh.form.key", defaultValue: "Key"), selection: $draft.keyID) {
                Text(L10n.string("mobile.ssh.form.key.none", defaultValue: "None"))
                    .tag(UUID?.none)
                ForEach(computers.keys) { key in
                    Text(key.label).tag(UUID?.some(key.id))
                }
            }
            .accessibilityIdentifier("ssh.form.key")
            NavigationLink {
                SSHGenerateKeyView(computers: computers) { record in
                    draft.keyID = record.id
                }
            } label: {
                Text(L10n.string("mobile.ssh.form.key.generate", defaultValue: "Generate New Key…"))
            }
            .accessibilityIdentifier("ssh.form.key.generate")
            NavigationLink {
                SSHImportKeyView(computers: computers) { record in
                    draft.keyID = record.id
                }
            } label: {
                Text(L10n.string("mobile.ssh.form.key.import", defaultValue: "Import Key…"))
            }
            .accessibilityIdentifier("ssh.form.key.import")
            NavigationLink {
                SSHKeysView(computers: computers)
            } label: {
                Text(L10n.string("mobile.ssh.form.key.manage", defaultValue: "Manage Keys"))
            }
            .accessibilityIdentifier("ssh.form.key.manage")
        } header: {
            Text(L10n.string("mobile.ssh.form.key.header", defaultValue: "Login Key"))
        } footer: {
            if let selectedKey {
                Text(selectedKey.fingerprint)
                    .font(.caption.monospaced())
            }
        }
    }

    private func installSection(key: SSHKeyRecord) -> some View {
        Section {
            Text(key.publicKeyLine)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(4)
                .accessibilityIdentifier("ssh.form.publicKey")
            HStack(spacing: 20) {
                Button {
                    UIPasteboard.general.string = key.publicKeyLine
                } label: {
                    Label(SSHCopy.copy, systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("ssh.form.publicKey.copy")
                ShareLink(item: key.publicKeyLine) {
                    Label(
                        L10n.string("mobile.ssh.form.publicKey.share", defaultValue: "Share"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("ssh.form.publicKey.share")
            }
            Button {
                showsValidation = true
                guard draft.validationMessage == nil else { return }
                installState = .idle
                isAskingPassword = true
            } label: {
                HStack {
                    Text(L10n.string("mobile.ssh.install.button", defaultValue: "Install with Password…"))
                    Spacer()
                    installStatusAccessory
                }
            }
            .disabled(installState == .installing)
            .accessibilityIdentifier("ssh.form.install")
            switch installState {
            case .succeeded:
                Text(L10n.string(
                    "mobile.ssh.install.success",
                    defaultValue: "Key installed. This iPhone can now log in without a password."
                ))
                .font(.footnote)
                .foregroundStyle(.green)
                .accessibilityIdentifier("ssh.install.success")
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("ssh.install.failure")
            case .idle, .installing:
                EmptyView()
            }
        } header: {
            Text(L10n.string("mobile.ssh.install.header", defaultValue: "Set Up This Key on the Server"))
        } footer: {
            // One footer: the password path only works where the server
            // allows password login, so the manual path is the fallback.
            Text(L10n.string(
                "mobile.ssh.install.footer",
                defaultValue: "Add this public key to ~/.ssh/authorized_keys on the computer, or let cmux do it with your password once. The password is never saved."
            ) + " " + L10n.string(
                "mobile.ssh.install.passwordNote",
                defaultValue: "Some servers turn off password login. If this fails, add the key above to ~/.ssh/authorized_keys."
            ))
            .accessibilityIdentifier("ssh.install.footer")
        }
    }

    @ViewBuilder
    private var installStatusAccessory: some View {
        switch installState {
        case .installing:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private var sessionSection: some View {
        Section {
            NavigationLink {
                SSHPersistenceChoiceView(selection: $draft.persistence)
            } label: {
                LabeledContent(
                    L10n.string("mobile.ssh.form.persistence", defaultValue: "Keep Sessions Alive"),
                    value: draft.persistence?.sshDisplayName ?? SSHCopy.askOnFirstConnect
                )
            }
            .accessibilityIdentifier("ssh.form.persistence")
        } footer: {
            Text(draft.persistence?.sshDescription ?? L10n.string(
                "mobile.ssh.persistence.ask.description",
                defaultValue: "cmux checks what the computer supports and asks the first time you connect."
            ))
        }
    }

    private var idleSection: some View {
        Section {
            Picker(
                L10n.string("mobile.ssh.form.idleClose", defaultValue: "Close Idle Sessions After"),
                selection: $draft.idleClose
            ) {
                ForEach([SSHIdleClosePolicy.oneHour, .oneDay, .sevenDays, .never], id: \.self) { policy in
                    Text(policy.sshDisplayName).tag(policy)
                }
            }
            .accessibilityIdentifier("ssh.form.idleClose")
        } footer: {
            Text(L10n.string(
                "mobile.ssh.form.idleClose.footer",
                defaultValue: "Applies to cmux-tui sessions you've left running on the computer."
            ))
        }
    }

    private var jumpSection: some View {
        Section {
            Picker(
                L10n.string("mobile.ssh.form.jumpHost", defaultValue: "Jump Host"),
                selection: $draft.jumpHostID
            ) {
                Text(L10n.string("mobile.ssh.form.jumpHost.none", defaultValue: "None"))
                    .tag(UUID?.none)
                ForEach(jumpCandidates) { host in
                    Text(host.name).tag(UUID?.some(host.id))
                }
            }
            .disabled(jumpCandidates.isEmpty)
            .accessibilityIdentifier("ssh.form.jumpHost")
        } footer: {
            Text(L10n.string(
                "mobile.ssh.form.jumpHost.footer",
                defaultValue: "Connect through another saved SSH computer first, like ssh -J."
            ))
        }
    }

    // MARK: Actions

    /// Persists the draft. Returns the saved id, or `nil` after showing why not.
    private func persist() async -> UUID? {
        showsValidation = true
        let current = existing ?? computers.host(id: hostID)
        guard let record = draft.record(id: hostID, existing: current) else { return nil }
        do {
            try await computers.saveHost(record)
            saveError = nil
            return record.id
        } catch {
            saveError = String(
                format: L10n.string("mobile.ssh.form.error.save", defaultValue: "Couldn't save: %@"),
                error.localizedDescription
            )
            return nil
        }
    }

    private func saveAndFinish() async {
        isSaving = true
        defer { isSaving = false }
        guard let id = await persist() else { return }
        onFinish(id)
    }

    private func install(password: String) async {
        installState = .installing
        guard let id = await persist() else {
            installState = .idle
            return
        }
        do {
            try await computers.installKey(hostID: id, password: password)
            installState = .succeeded
        } catch {
            installState = .failed(Self.installFailureMessage(error))
        }
    }

    private func delete() async {
        do {
            try await computers.deleteHost(id: hostID)
            onFinish(nil)
        } catch {
            saveError = error.localizedDescription
        }
    }

    static func installFailureMessage(_ error: any Error) -> String {
        switch error {
        case SSHConnectionError.authenticationFailed:
            L10n.string(
                "mobile.ssh.install.error.auth",
                defaultValue: "The server didn't accept that password. Check the username and password, and that the server allows password login."
            )
        case SSHConnectionError.hostKeyRejected:
            L10n.string("mobile.ssh.error.hostKeyRejected", defaultValue: "Connection cancelled: server identity not trusted.")
        case SSHConnectionError.channelRequestRejected:
            L10n.string(
                "mobile.ssh.install.error.write",
                defaultValue: "Logged in, but couldn't update ~/.ssh/authorized_keys on the server."
            )
        default:
            String(
                format: L10n.string("mobile.ssh.install.error.generic", defaultValue: "Couldn't install the key: %@"),
                error.localizedDescription
            )
        }
    }
}
extension View {
    /// SSH fields hold technical text (hostnames, user names, key and host
    /// names like "Behind jump (tmux)"): never autocorrect or capitalize it.
    func sshLiteralTextEntry() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
#endif
