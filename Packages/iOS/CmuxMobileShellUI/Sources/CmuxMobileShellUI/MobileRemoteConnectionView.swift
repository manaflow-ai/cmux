#if os(iOS)
import CmuxRemoteConnections
import SwiftUI

/// Form and lightweight terminal surface for the first direct SSH flow.
///
/// The connection service owns account checks, host trust, and credential
/// ordering. This view deliberately keeps terminal bytes in a scrollable text
/// surface until it is replaced by the existing Ghostty surface host; it is a
/// functional connection path, not a second SSH implementation.
struct MobileRemoteConnectionView: View {
    let controller: any MobileRemoteConnectionServing
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var backend: MobileRemoteSessionBackend = .shell
    @State private var output = ""
    @State private var input = ""
    @State private var session: (any MobileRemoteSSHSession)?
    @State private var outputTask: Task<Void, Never>?
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var approval = MobileRemoteHostApprovalState()

    var body: some View {
        Form {
            Section {
                TextField(L10n.string("mobile.remote.host", defaultValue: "Host"), text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.string("mobile.remote.port", defaultValue: "Port"), text: $port)
                    .keyboardType(.numberPad)
                TextField(L10n.string("mobile.remote.username", defaultValue: "Username"), text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.string("mobile.remote.password", defaultValue: "Password"), text: $password)
                Picker(L10n.string("mobile.remote.session", defaultValue: "Session"), selection: $backend) {
                    Text(L10n.string("mobile.remote.shell", defaultValue: "Shell")).tag(MobileRemoteSessionBackend.shell)
                    Text(L10n.string("mobile.remote.cmux", defaultValue: "cmux")).tag(MobileRemoteSessionBackend.cmuxTUI)
                }
            } header: {
                Text(L10n.string("mobile.remote.section", defaultValue: "Remote connection"))
            } footer: {
                Text(L10n.string("mobile.remote.accountFooter", defaultValue: "Your cmux account is required before SSH credentials are requested."))
            }

            Section {
                Button(isConnecting ? L10n.string("mobile.remote.connecting", defaultValue: "Connecting…") : L10n.string("mobile.remote.connect", defaultValue: "Connect")) {
                    Task { await connect() }
                }
                .disabled(isConnecting || session != nil)
                .accessibilityIdentifier("MobileRemoteConnectButton")

                if session != nil {
                    Button(L10n.string("mobile.remote.disconnect", defaultValue: "Disconnect"), role: .destructive) {
                        Task { await disconnect() }
                    }
                    .accessibilityIdentifier("MobileRemoteDisconnectButton")
                }
            }

            if !output.isEmpty || session != nil {
                Section(L10n.string("mobile.remote.terminal", defaultValue: "Terminal")) {
                    ScrollView {
                        Text(output.isEmpty ? L10n.string("mobile.remote.connected", defaultValue: "Connected") : output)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    HStack {
                        TextField(L10n.string("mobile.remote.input", defaultValue: "Input"), text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(L10n.string("mobile.remote.send", defaultValue: "Send")) {
                            Task { await sendInput() }
                        }
                        .disabled(input.isEmpty || session == nil)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Remote")
        .confirmationDialog(
            L10n.string("mobile.remote.trustTitle", defaultValue: "Trust this SSH host?"),
            isPresented: Binding(
                get: { approval.challenge != nil },
                set: { if !$0 { approval.cancel() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("mobile.remote.trust", defaultValue: "Trust Host")) { approval.resolve(true) }
            Button(L10n.string("mobile.remote.cancel", defaultValue: "Cancel"), role: .cancel) { approval.resolve(false) }
        } message: {
            if let challenge = approval.challenge {
                Text("\(challenge.algorithm)\n\(challenge.fingerprint)")
            }
        }
        .onDisappear {
            outputTask?.cancel()
            Task { await session?.close() }
            approval.cancel()
        }
    }

    private func connect() async {
        guard let port = Int(port), !host.isEmpty, !username.isEmpty else {
            errorMessage = L10n.string("mobile.remote.requiredFields", defaultValue: "Enter a host, port, and username.")
            return
        }
        isConnecting = true
        errorMessage = nil
        do {
            let profile = try MobileRemoteProfile(
                id: UUID(), host: host, port: port, username: username,
                authentication: .password, sessionBackend: backend
            )
            let connected = try await controller.connect(
                profile: profile,
                credential: MobileRemoteSSHCredentialSource { .password(password) },
                approveUnknownHost: { challenge in await approval.request(challenge) }
            )
            session = connected
            outputTask = Task { @MainActor in
                do {
                    for try await data in connected.output() {
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        output.append(text)
                    }
                } catch {
                    errorMessage = L10n.string("mobile.remote.outputStopped", defaultValue: "Remote output stopped.")
                }
            }
        } catch {
            errorMessage = String(describing: error)
        }
        isConnecting = false
    }

    private func sendInput() async {
        guard let session, !input.isEmpty else { return }
        let data = Data((input + "\n").utf8)
        input = ""
        do { try await session.sendInput(data) }
        catch { errorMessage = L10n.string("mobile.remote.sendFailed", defaultValue: "Could not send input.") }
    }

    private func disconnect() async {
        outputTask?.cancel()
        outputTask = nil
        await session?.close()
        session = nil
    }
}
#endif
