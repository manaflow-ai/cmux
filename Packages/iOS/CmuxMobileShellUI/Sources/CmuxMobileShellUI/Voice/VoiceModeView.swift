#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The root-level orchestrator voice button, styled as a sibling of
/// ``TaskComposerButton`` in the bottom-trailing control stack.
struct VoiceModeButton: View {
    let action: () -> Void
    var diameter: CGFloat = 52

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .mobileGlassPill()
        .accessibilityLabel(L10n.string("mobile.voice.button", defaultValue: "Voice Mode"))
        .accessibilityHint(
            L10n.string(
                "mobile.voice.button.hint",
                defaultValue: "Starts a voice conversation about your workspaces."
            )
        )
        .accessibilityIdentifier("MobileVoiceModeButton")
    }
}

/// The live voice conversation sheet, shared by the orchestrator and
/// per-workspace entrypoints (one controller, one surface).
struct VoiceModeView: View {
    let store: CMUXMobileShellStore
    let settings: MobileVoiceSettings
    let mode: VoiceSessionController.Mode

    @State private var controller: VoiceSessionController?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let controller {
                    VoiceModeContentView(controller: controller)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L10n.string("mobile.voice.title", defaultValue: "Voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controller?.stop()
                        dismiss()
                    } label: {
                        Text(L10n.string("mobile.voice.end", defaultValue: "End"))
                    }
                    .accessibilityIdentifier("MobileVoiceModeEndButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard controller == nil else { return }
            let controller = VoiceSessionController(
                store: store,
                settings: settings,
                mode: mode
            )
            self.controller = controller
            controller.start()
        }
        .onDisappear {
            controller?.stop()
        }
    }
}

private struct VoiceModeContentView: View {
    @Bindable var controller: VoiceSessionController

    var body: some View {
        VStack(spacing: 16) {
            statusHeader
                .padding(.top, 12)
            transcriptList
            controls
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch controller.phase {
        case .idle, .connecting:
            Label {
                Text(L10n.string("mobile.voice.state.connecting", defaultValue: "Connecting…"))
            } icon: {
                ProgressView()
            }
            .foregroundStyle(.secondary)
        case .live:
            VStack(spacing: 6) {
                Image(systemName: controller.isAssistantSpeaking
                    ? "waveform.and.person.filled"
                    : "waveform")
                    .font(.system(size: 34, weight: .medium))
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .foregroundStyle(controller.isAssistantSpeaking ? Color.accentColor : .primary)
                Text(controller.isAssistantSpeaking
                    ? L10n.string("mobile.voice.state.speaking", defaultValue: "Speaking")
                    : L10n.string("mobile.voice.state.listening", defaultValue: "Listening"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if controller.usesTerminalFallback {
                    Text(L10n.string(
                        "mobile.voice.terminalFallback",
                        defaultValue: "No agent session found. Your words are typed into the terminal."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
            }
        case .ended:
            Text(L10n.string("mobile.voice.state.ended", defaultValue: "Voice session ended."))
                .foregroundStyle(.secondary)
        case .failed(let reason):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(Self.failureText(reason))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.transcript) { line in
                        VoiceTranscriptRow(line: line)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: controller.transcript.last?.text) { _, _ in
                guard let lastID = controller.transcript.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var controls: some View {
        if controller.phase == .live {
            Button {
                controller.microphoneMuted.toggle()
            } label: {
                Label {
                    Text(controller.microphoneMuted
                        ? L10n.string("mobile.voice.unmute", defaultValue: "Unmute")
                        : L10n.string("mobile.voice.mute", defaultValue: "Mute"))
                } icon: {
                    Image(systemName: controller.microphoneMuted ? "mic.slash.fill" : "mic.fill")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(controller.microphoneMuted ? .red : nil)
            .accessibilityIdentifier("MobileVoiceModeMuteButton")
        }
    }

    private static func failureText(_ reason: VoiceSessionController.FailureReason) -> String {
        switch reason {
        case .microphoneDenied:
            return L10n.string(
                "mobile.voice.error.micDenied",
                defaultValue: "Microphone access is off for cmux. Enable it in Settings to use voice mode."
            )
        case .audioUnavailable:
            return L10n.string(
                "mobile.voice.error.audio",
                defaultValue: "Couldn't start audio. Close other audio apps and try again."
            )
        case .credentialMissing:
            return L10n.string(
                "mobile.voice.error.noCredential",
                defaultValue: "Voice mode needs an OpenAI API key. Add one in Settings › Voice Mode."
            )
        case .connectionFailed:
            return L10n.string(
                "mobile.voice.error.connection",
                defaultValue: "Voice connection failed. Check your network and try again."
            )
        }
    }
}

private struct VoiceTranscriptRow: View {
    let line: VoiceSessionController.TranscriptLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.role == .user
                ? L10n.string("mobile.voice.transcript.you", defaultValue: "You")
                : L10n.string("mobile.voice.transcript.assistant", defaultValue: "Assistant"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(line.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
