import SwiftUI
import UIKit

public struct ContentView: View {
    @State private var ticket = ""
    @State private var message: String
    @State private var terminalCommand: String
    @State private var status: PingStatus = .idle
    @State private var terminalStatus: TerminalStatus = .idle
    @State private var lastPingLatencyMS: Int64?
    @State private var lastTerminalLatencyMS: Int64?

    private let client = IrohDemoClient()

    public init() {
        _message = State(initialValue: localized("iroh.demo.defaultMessage", "Hello from iPhone"))
        _terminalCommand = State(initialValue: localized("iroh.demo.terminal.defaultCommand", "pwd && uname -a"))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $ticket)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(localized("iroh.demo.ticket.accessibility", "Iroh ticket"))

                    Button {
                        pasteTicket()
                    } label: {
                        Label(
                            localized("iroh.demo.pasteTicket", "Paste Ticket"),
                            systemImage: "doc.on.clipboard"
                        )
                    }
                } header: {
                    Text(localized("iroh.demo.ticket.header", "Mac Ticket"))
                } footer: {
                    Text(localized("iroh.demo.ticket.footer", "Copy the ticket from the Mac TUI and paste it here."))
                }

                Section {
                    TextField(
                        localized("iroh.demo.message.placeholder", "Message"),
                        text: $message,
                        axis: .vertical
                    )
                    .lineLimit(2...4)

                    Button {
                        pingMac()
                    } label: {
                        Label(localized("iroh.demo.pingMac", "Ping Mac"), systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status.isSending)
                } header: {
                    Text(localized("iroh.demo.message.header", "Request"))
                }

                Section {
                    latencyView
                } header: {
                    Text(localized("iroh.demo.latency.header", "Latency"))
                }

                Section {
                    TextField(
                        localized("iroh.demo.terminal.placeholder", "Command"),
                        text: $terminalCommand,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel(localized("iroh.demo.terminal.accessibility", "PTY command"))

                    Button {
                        runTerminal()
                    } label: {
                        Label(localized("iroh.demo.terminal.run", "Run PTY"), systemImage: "terminal")
                    }
                    .disabled(
                        ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || terminalStatus.isSending
                    )

                    terminalStatusView
                } header: {
                    Text(localized("iroh.demo.terminal.header", "Mac PTY"))
                }

                Section {
                    statusView
                } header: {
                    Text(localized("iroh.demo.status.header", "Status"))
                }
            }
            .navigationTitle(localized("iroh.demo.title", "Iroh Link"))
        }
    }

    @ViewBuilder
    private var latencyView: some View {
        if lastPingLatencyMS == nil, lastTerminalLatencyMS == nil {
            Label(localized("iroh.demo.latency.empty", "No latency sample yet"), systemImage: "speedometer")
                .foregroundStyle(.secondary)
        } else {
            if let lastPingLatencyMS {
                LabeledContent(
                    localized("iroh.demo.latency.ping", "Ping"),
                    value: String(format: localized("iroh.demo.latency.value", "%lld ms"), lastPingLatencyMS)
                )
            }

            if let lastTerminalLatencyMS {
                LabeledContent(
                    localized("iroh.demo.latency.terminal", "PTY"),
                    value: String(format: localized("iroh.demo.latency.value", "%lld ms"), lastTerminalLatencyMS)
                )
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Label(localized("iroh.demo.idle", "Waiting for a ticket"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .sending:
            HStack {
                ProgressView()
                Text(localized("iroh.demo.sending", "Connecting over iroh"))
            }
        case .success(let result):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    String(
                        format: localized("iroh.demo.success", "Connected in %lld ms"),
                        result.rttMS
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                Text(result.reply)
                    .font(.body)
                    .textSelection(.enabled)

                Text(
                    String(
                        format: localized("iroh.demo.remote", "Remote: %@"),
                        result.remoteID
                    )
                )
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var terminalStatusView: some View {
        switch terminalStatus {
        case .idle:
            Label(localized("iroh.demo.terminal.idle", "Waiting to run a PTY command"), systemImage: "terminal")
                .foregroundStyle(.secondary)
        case .sending:
            HStack {
                ProgressView()
                Text(localized("iroh.demo.terminal.sending", "Running in Mac PTY"))
            }
        case .success(let result):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    String(
                        format: localized("iroh.demo.terminal.success", "PTY returned in %lld ms"),
                        result.rttMS
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                Text(
                    String(
                        format: localized("iroh.demo.terminal.exit", "Exit: %@"),
                        result.exitCode.map(String.init) ?? localized("iroh.demo.terminal.exitUnknown", "unknown")
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text(result.output.isEmpty ? localized("iroh.demo.terminal.emptyOutput", "No output") : result.output)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func pasteTicket() {
        guard let pasted = UIPasteboard.general.string else {
            status = .failure(localized("iroh.demo.noPasteboardText", "The pasteboard does not contain text."))
            return
        }

        ticket = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pingMac() {
        let trimmedTicket = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTicket.isEmpty else {
            status = .failure(localized("iroh.demo.missingTicket", "Paste a Mac ticket first."))
            return
        }

        status = .sending
        Task {
            let result = await client.ping(ticket: trimmedTicket, message: message)
            switch result {
            case .success(let value):
                status = .success(value)
                lastPingLatencyMS = value.rttMS
            case .failure(let error):
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func runTerminal() {
        let trimmedTicket = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTicket.isEmpty else {
            terminalStatus = .failure(localized("iroh.demo.missingTicket", "Paste a Mac ticket first."))
            return
        }

        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            terminalStatus = .failure(localized("iroh.demo.terminal.missingCommand", "Enter a command first."))
            return
        }

        terminalStatus = .sending
        Task {
            let result = await client.terminalCommand(ticket: trimmedTicket, command: command)
            switch result {
            case .success(let value):
                terminalStatus = .success(value)
                lastTerminalLatencyMS = value.rttMS
            case .failure(let error):
                terminalStatus = .failure(error.localizedDescription)
            }
        }
    }
}

private enum PingStatus {
    case idle
    case sending
    case success(IrohPingResult)
    case failure(String)

    var isSending: Bool {
        if case .sending = self {
            return true
        }
        return false
    }
}

private enum TerminalStatus {
    case idle
    case sending
    case success(IrohTerminalResult)
    case failure(String)

    var isSending: Bool {
        if case .sending = self {
            return true
        }
        return false
    }
}

private func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: defaultValue, bundle: .module)
}
