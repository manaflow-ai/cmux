import SwiftUI

struct SessionView: View {
    @State private var model = SessionModel()
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        switch model.phase {
        case .connected:
            terminal
        default:
            connect
        }
    }

    private var connect: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("cmux://enroll/…", text: $model.invitation, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste") {
                        model.invitation = UIPasteboard.general.string ?? model.invitation
                    }
                } header: {
                    Text("Invitation")
                } footer: {
                    Text("Run `cmux-tui daemon invite` on the machine you want to reach. "
                        + "The invitation expires in five minutes and the daemon asks that "
                        + "machine's owner to approve this device.")
                }

                Section("Workspace") {
                    TextField("Directory", text: $model.root)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Path", selection: $model.pathMode) {
                        Text("Automatic").tag(RemoteClient.PathMode.auto)
                        Text("Direct only").tag(RemoteClient.PathMode.directOnly)
                        Text("Relay only").tag(RemoteClient.PathMode.relayOnly)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Network path")
                } footer: {
                    Text("Automatic starts on whichever path connects and upgrades to a "
                        + "direct one when hole punching succeeds. The constrained modes "
                        + "exist to prove each path separately.")
                }

                if case .failed(let message) = model.phase {
                    Section {
                        Text(message).foregroundStyle(.red).font(.footnote)
                    }
                }

                Button(model.phase == .connecting ? "Connecting…" : "Connect") {
                    model.connect()
                }
                .disabled(model.invitation.isEmpty || model.phase == .connecting)
            }
            .navigationTitle("cmux remote")
        }
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                TerminalScreen(snapshot: model.terminal, fontSize: 11)
                    .onAppear { model.resize(to: TerminalMetrics(fontSize: 11).grid(in: geometry.size)) }
                    .onChange(of: geometry.size) { _, size in
                        model.resize(to: TerminalMetrics(fontSize: 11).grid(in: size))
                    }
                    .onTapGesture { keyboardFocused = true }
            }

            KeyboardBar(model: model)
            statusBar
        }
        .background(.black)
        .overlay(alignment: .bottom) {
            // Off-screen catcher: iOS only raises the keyboard for a focused
            // text responder, and keystrokes are forwarded rather than edited.
            KeyboardCatcher { text in model.send(text) }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($keyboardFocused)
        }
        .onAppear { keyboardFocused = true }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let connection = model.connection {
                Label(connection.pathLabel, systemImage: pathIcon(connection.pathLabel))
                Text(connection.provider)
                if connection.generation > 0 {
                    // A bumped generation means the carrier dropped and the
                    // session resumed, which is the interesting case on a phone.
                    Text("resumed ×\(connection.generation)")
                }
            } else {
                Text("connecting…")
            }
            Spacer()
            Button("Disconnect") { model.disconnect() }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func pathIcon(_ label: String) -> String {
        switch label {
        case "Direct": "bolt.horizontal"
        case "Relay": "arrow.triangle.branch"
        default: "hourglass"
        }
    }
}

/// The keys a terminal needs that a phone keyboard has no room for.
private struct KeyboardBar: View {
    let model: SessionModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("esc", "\u{1b}")
                key("tab", "\t")
                key("^C", "\u{03}")
                key("^D", "\u{04}")
                key("^Z", "\u{1a}")
                key("^L", "\u{0c}")
                key("↑", "\u{1b}[A")
                key("↓", "\u{1b}[B")
                key("←", "\u{1b}[D")
                key("→", "\u{1b}[C")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func key(_ label: String, _ bytes: String) -> some View {
        Button(label) { model.send(bytes) }
            .font(.system(size: 13, design: .monospaced))
            .buttonStyle(.bordered)
    }
}

/// A UIKit responder that forwards keystrokes instead of holding text.
///
/// SwiftUI's TextField owns an editing buffer, which fights a terminal: the
/// remote shell decides what the screen shows, so the phone must send each
/// keystroke and keep no local state.
private struct KeyboardCatcher: UIViewRepresentable {
    let onInput: (String) -> Void

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onInput = onInput
        return view
    }

    func updateUIView(_ view: CatcherView, context: Context) {
        view.onInput = onInput
    }

    final class CatcherView: UIView, UIKeyInput {
        var onInput: ((String) -> Void)?

        override var canBecomeFirstResponder: Bool { true }
        var hasText: Bool { true }

        var keyboardType: UIKeyboardType = .asciiCapable
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no

        func insertText(_ text: String) {
            onInput?(text)
        }

        func deleteBackward() {
            // The shell's line editor handles erasure, so send the byte a tty
            // sends rather than editing anything locally.
            onInput?("\u{7f}")
        }
    }
}
