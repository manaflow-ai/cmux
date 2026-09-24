#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// "Open Port in Browser…" for an SSH computer (PRD D7): forwards a port on
/// the phone's loopback to a port the server can reach, then opens it in the
/// native in-app browser. Also lists this host's active forwards.
struct SSHPortForwardSheet: View {
    let hostID: UUID
    let computers: MobileSSHComputers
    /// Opens a URL in the workspace's native browser pane.
    let openInBrowser: (URL) -> Void

    @State private var portText = ""
    @State private var remoteHost = ""
    @State private var isStarting = false
    @State private var errorMessage: String?
    @FocusState private var isPortFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let defaultRemoteHost = "127.0.0.1"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L10n.string("mobile.ssh.forward.port.label", defaultValue: "Port")) {
                        TextField(
                            L10n.string("mobile.ssh.forward.port.label", defaultValue: "Port"),
                            text: $portText,
                            prompt: Text(verbatim: "3000")
                        )
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .focused($isPortFocused)
                        .accessibilityIdentifier("ssh.forward.port")
                    }
                    LabeledContent(L10n.string("mobile.ssh.forward.host.label", defaultValue: "Host")) {
                        TextField(
                            L10n.string("mobile.ssh.forward.host.label", defaultValue: "Host"),
                            text: $remoteHost,
                            prompt: Text(verbatim: Self.defaultRemoteHost)
                        )
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("ssh.forward.host")
                    }
                } header: {
                    Text(L10n.string("mobile.ssh.forward.section.port", defaultValue: "Port on the Computer"))
                } footer: {
                    Text(L10n.string(
                        "mobile.ssh.forward.footer",
                        defaultValue: "Opens a web server running on this computer, such as a dev server, in the in-app browser. The connection stays open while cmux is in the foreground. Leave the host empty for the computer itself."
                    ))
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if !forwards.isEmpty {
                    Section(L10n.string("mobile.ssh.forward.section.active", defaultValue: "Open Ports")) {
                        ForEach(forwards, id: \.localPort) { forward in
                            forwardRow(forward)
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.ssh.forward.title", defaultValue: "Open Port"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.ssh.files.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isStarting {
                        ProgressView()
                    } else {
                        Button(L10n.string("mobile.ssh.forward.start", defaultValue: "Open")) {
                            Task { await start() }
                        }
                        .disabled(remotePort == nil)
                        .accessibilityIdentifier("ssh.forward.start")
                    }
                }
            }
            .onAppear { isPortFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var forwards: [SSHLocalPortForward] {
        computers.forwardsByHost[hostID] ?? []
    }

    private var remotePort: Int? {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    private func forwardRow(_ forward: SSHLocalPortForward) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(forward.targetHost):\(forward.targetPort)")
                    .font(.body.monospacedDigit())
                Text(verbatim: "localhost:\(forward.localPort)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string("mobile.ssh.forward.openExisting", defaultValue: "Open")) {
                open(localPort: forward.localPort)
            }
            .buttonStyle(.borderless)
            Button(L10n.string("mobile.ssh.forward.stop", defaultValue: "Stop"), role: .destructive) {
                Task { await computers.stopPortForward(hostID: hostID, localPort: forward.localPort) }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("ssh.forward.stop.\(forward.localPort)")
        }
        .accessibilityIdentifier("ssh.forward.row.\(forward.targetPort)")
    }

    private func start() async {
        guard let port = remotePort else { return }
        let host = remoteHost.trimmingCharacters(in: .whitespaces)
        let target = host.isEmpty ? Self.defaultRemoteHost : host
        // Reuse a live forward to the same target instead of stacking listeners.
        if let existing = forwards.first(where: { $0.targetPort == port && $0.targetHost == target }) {
            open(localPort: existing.localPort)
            return
        }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let forward = try await computers.startPortForward(hostID: hostID, remotePort: port, remoteHost: target)
            open(localPort: forward.localPort)
        } catch {
            errorMessage = L10n.string(
                "mobile.ssh.forward.error",
                defaultValue: "Couldn't open the port. Check that this computer is connected and try again."
            )
        }
    }

    private func open(localPort: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/") else { return }
        dismiss()
        openInBrowser(url)
    }
}
#endif
