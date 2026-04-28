import SwiftUI
import WebKit

struct VoicePanelView: View {
    @StateObject private var viewModel = VoiceAgentViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptView
            Divider()
            composer
            VoiceRealtimeWebView(bridge: viewModel.bridge)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text(String(localized: "rightSidebar.mode.voice", defaultValue: "Voice"))
            } icon: {
                Image(systemName: "waveform.circle")
            }
            .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 0)

            micMeter
            statusPill

            Button {
                viewModel.toggleMute()
            } label: {
                Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(viewModel.isMuted
                ? String(localized: "voice.action.unmute", defaultValue: "Unmute")
                : String(localized: "voice.action.mute", defaultValue: "Mute")
            )
            .disabled(!viewModel.state.isConnected)

            Button {
                if viewModel.state.isActive {
                    viewModel.disconnect()
                } else {
                    viewModel.connect()
                }
            } label: {
                Image(systemName: viewModel.state.isActive ? "stop.fill" : "mic.badge.plus")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(viewModel.state.isActive
                ? String(localized: "voice.action.stop", defaultValue: "Stop")
                : String(localized: "voice.action.start", defaultValue: "Start")
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var micMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(micBarColor(for: index))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }
        .frame(width: 18, height: 16)
        .help(viewModel.microphoneReady
            ? String(localized: "voice.microphone.ready", defaultValue: "Microphone active")
            : String(localized: "voice.microphone.waiting", defaultValue: "Waiting for microphone")
        )
        .accessibilityIdentifier("VoiceMicrophoneMeter")
    }

    private func micBarColor(for index: Int) -> Color {
        guard viewModel.microphoneReady, viewModel.state.isConnected || viewModel.state == .connecting else {
            return .secondary.opacity(0.25)
        }
        let threshold = Double(index + 1) / 4.0
        return viewModel.microphoneLevel >= threshold ? .green : .secondary.opacity(0.25)
    }

    private var statusPill: some View {
        Text(statusText)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(statusForeground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(statusBackground)
            )
            .accessibilityIdentifier("VoiceStatusPill")
    }

    private var statusText: String {
        if !viewModel.currentActivity.isEmpty {
            return viewModel.currentActivity
        }
        return viewModel.state.localizedTitle
    }

    private var statusForeground: Color {
        switch viewModel.state {
        case .connected:
            return .green
        case .failed:
            return .red
        case .preparing, .connecting:
            return .orange
        case .disconnected:
            return .secondary
        }
    }

    private var statusBackground: Color {
        statusForeground.opacity(0.12)
    }

    private var transcriptView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.transcript.isEmpty {
                    Text(String(localized: "voice.empty", defaultValue: "No messages"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 28)
                } else {
                    ForEach(viewModel.transcript) { item in
                        VoiceTranscriptRow(item: item)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("VoiceTranscript")
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "voice.composer.placeholder", defaultValue: "Ask cmux"),
                text: $viewModel.promptText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .onSubmit {
                viewModel.sendPromptText()
            }
            .disabled(!viewModel.state.isConnected)

            Button {
                viewModel.sendPromptText()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .help(String(localized: "voice.action.send", defaultValue: "Send"))
            .disabled(!viewModel.state.isConnected || viewModel.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
    }
}

private struct VoiceTranscriptRow: View {
    let item: VoiceTranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.role.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(roleColor)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.role.localizedLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var roleColor: Color {
        switch item.role {
        case .user:
            return .accentColor
        case .assistant:
            return .green
        case .tool:
            return .orange
        case .system:
            return .secondary
        case .error:
            return .red
        }
    }
}

private struct VoiceRealtimeWebView: NSViewRepresentable {
    let bridge: VoiceRealtimeWebRTCBridge

    func makeNSView(context: Context) -> WKWebView {
        bridge.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
