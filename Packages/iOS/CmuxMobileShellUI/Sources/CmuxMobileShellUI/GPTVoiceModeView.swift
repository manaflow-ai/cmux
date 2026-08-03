#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxVoice
import SwiftUI

/// Full-duplex GPT Realtime conversation that can route speech across paired Macs.
struct GPTVoiceModeView: View {
    @Environment(RealtimeVoiceRuntime.self) private var runtime
    @Environment(VoiceSettingsStore.self) private var voiceSettings
    @Environment(\.dismiss) private var dismiss

    let store: CMUXMobileShellStore
    let connectedHostName: String

    @State private var permissionRequestInFlight = false
    @State private var sessionGeneration = 0
    @State private var showingHostPicker = false
    @State private var permissionError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                GPTVoiceTargetSummaryView(
                    computerCount: computerCount,
                    terminalCount: terminalCount
                )
                GPTVoiceConversationView(
                    transcripts: runtime.transcripts,
                    partialUserTranscript: runtime.partialUserTranscript,
                    partialAssistantTranscript: runtime.partialAssistantTranscript
                )
                Spacer(minLength: 0)
                VoiceModeMicrophoneControl(
                    isListening: sessionIsActive,
                    isStarting: runtime.state == .connecting || permissionRequestInFlight,
                    isEnabled: terminalCount > 0 || sessionIsActive || permissionRequestInFlight
                ) {
                    if sessionIsActive || permissionRequestInFlight {
                        Task { await stopSession() }
                    } else {
                        Task { await startSession() }
                    }
                }
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("MobileGPTVoiceStatus")
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("MobileGPTVoiceError")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .navigationTitle(L10n.string(
                "mobile.voiceMode.gpt.title",
                defaultValue: "GPT Voice"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingHostPicker = true
                    } label: {
                        Image(systemName: "macbook.and.iphone")
                    }
                    .accessibilityLabel(L10n.string(
                        "mobile.settings.switchMac",
                        defaultValue: "Switch Computer"
                    ))
                    .accessibilityIdentifier("MobileGPTVoiceComputers")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.string(
                        "mobile.settings.done",
                        defaultValue: "Done"
                    )) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileGPTVoiceDone")
                }
            }
            .sheet(isPresented: $showingHostPicker) {
                MobileHostPickerView(store: store)
            }
            .onDisappear {
                sessionGeneration += 1
                Task { await runtime.stop() }
            }
        }
        .accessibilityIdentifier("MobileGPTVoiceModeView")
    }

    private var availableWorkspaces: [MobileWorkspacePreview] {
        store.workspaces.filter {
            store.supportsGPTVoiceTarget(workspaceID: $0.id)
        }
    }

    private var terminalCount: Int {
        availableWorkspaces.reduce(into: 0) { count, workspace in
            count += workspace.terminals.lazy.filter(\.isReady).count
        }
    }

    private var computerCount: Int {
        Set(availableWorkspaces.map { workspace in
            workspace.macDeviceID
                ?? workspace.macDisplayName
                ?? workspace.id.rawValue
        }).count
    }

    private var sessionIsActive: Bool {
        switch runtime.state {
        case .connecting, .listening, .speaking, .working:
            true
        case .idle, .failed:
            false
        }
    }

    private var statusText: String {
        switch runtime.state {
        case .idle, .failed:
            return L10n.string(
                "mobile.voiceMode.startListening",
                defaultValue: "Start Listening"
            )
        case .connecting:
            return L10n.string(
                "mobile.voiceMode.gpt.connecting",
                defaultValue: "Connecting securely…"
            )
        case .listening:
            return L10n.string(
                "mobile.voiceMode.gpt.listening",
                defaultValue: "Listening"
            )
        case .speaking:
            return L10n.string(
                "mobile.voiceMode.gpt.speaking",
                defaultValue: "GPT is speaking"
            )
        case .working:
            return L10n.string(
                "mobile.voiceMode.gpt.routing",
                defaultValue: "Routing to terminals…"
            )
        }
    }

    private var errorText: String? {
        if let permissionError {
            return permissionError
        }
        guard let failure = runtime.failure else { return nil }
        switch failure {
        case .notAuthenticated:
            return L10n.string(
                "mobile.voiceMode.gpt.notAuthenticated",
                defaultValue: "Sign in again to use GPT Voice."
            )
        case .rateLimited:
            return L10n.string(
                "mobile.voiceMode.gpt.rateLimited",
                defaultValue: "Voice session limit reached. Try again shortly."
            )
        case .audioUnavailable:
            return L10n.string(
                "mobile.voiceMode.audioUnavailable",
                defaultValue: "The microphone could not start."
            )
        case .serviceUnavailable:
            return L10n.string(
                "mobile.voiceMode.gpt.serviceUnavailable",
                defaultValue: "GPT Voice is unavailable right now."
            )
        case .connectionLost:
            return L10n.string(
                "mobile.voiceMode.gpt.connectionLost",
                defaultValue: "The voice connection ended. Tap the microphone to reconnect."
            )
        }
    }

    @MainActor
    private func startSession() async {
        guard terminalCount > 0, !permissionRequestInFlight else { return }
        permissionError = nil
        sessionGeneration += 1
        let generation = sessionGeneration
        permissionRequestInFlight = true
        let permitted = await VoicePermissionRequester().requestMicrophonePermission()
        guard generation == sessionGeneration, permissionRequestInFlight else {
            return
        }
        permissionRequestInFlight = false
        guard permitted else {
            permissionError = L10n.string(
                "mobile.voiceMode.gpt.permissionDenied",
                defaultValue: "Microphone permission is required for GPT Voice."
            )
            return
        }
        guard terminalCount > 0 else { return }
        let executor = MobileShellVoiceToolExecutor(
            store: store,
            voiceSettings: voiceSettings
        )
        await runtime.start(toolExecutor: executor)
    }

    @MainActor
    private func stopSession() async {
        sessionGeneration += 1
        permissionRequestInFlight = false
        await runtime.stop()
    }
}
#endif
