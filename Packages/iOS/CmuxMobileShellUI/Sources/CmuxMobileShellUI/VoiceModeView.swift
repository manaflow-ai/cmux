#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileSupport
import CmuxVoice
import SwiftUI

/// Full-screen iPhone microphone mode for sending transcribed speech to the focused Mac terminal.
struct VoiceModeView: View {
    @Environment(VoiceSettingsStore.self) private var voiceSettings
    @Environment(ParakeetModelStore.self) private var parakeetModelStore
    @Environment(\.dismiss) private var dismiss

    let store: CMUXMobileShellStore
    let connectedHostName: String

    @State private var audioEngine = ComposerDictationAudioEngine()
    @State private var session: (any VoiceTranscriptionSession)?
    @State private var updateTask: Task<Void, Never>?
    /// Monotonic token for the current listening attempt. The audio engine
    /// reports ready ~100-300ms later on its own queue; a stop, failure, or a
    /// newer start in that window bumps this so the stale callback is discarded
    /// instead of flipping `isListening` back on (same pattern as
    /// `ComposerDictationController.startToken`).
    @State private var sessionGeneration = 0
    @State private var isListening = false
    @State private var isStarting = false
    @State private var partialTranscript = ""
    @State private var finalTranscripts: [String] = []
    @State private var sendConfirmation: String?
    @State private var errorMessage: String?
    @State private var showingHostPicker = false

    var body: some View {
        @Bindable var voiceSettings = voiceSettings
        return NavigationStack {
            VStack(spacing: 24) {
                targetCard
                transcriptArea
                Spacer(minLength: 8)
                micButton
                Toggle(isOn: $voiceSettings.voiceModeAutoSubmit) {
                    Text(L10n.string("mobile.voiceMode.autoSubmit", defaultValue: "Auto-submit"))
                }
                .accessibilityIdentifier("MobileVoiceModeAutoSubmit")
                if let sendConfirmation {
                    Text(sendConfirmation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("MobileVoiceModeConfirmation")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("MobileVoiceModeError")
                }
            }
            .padding(20)
            .navigationTitle(connectedHostName.isEmpty ? L10n.string("mobile.voiceMode.title", defaultValue: "Voice Mode") : connectedHostName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingHostPicker = true
                    } label: {
                        Image(systemName: "macbook.and.iphone")
                    }
                    .accessibilityLabel(L10n.string("mobile.settings.switchMac", defaultValue: "Switch Computer"))
                    .accessibilityIdentifier("MobileVoiceModeSwitchMac")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.string("mobile.settings.done", defaultValue: "Done")) {
                        stopListening()
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileVoiceModeDone")
                }
            }
            .task {
                await store.startVoiceFocusUpdates()
            }
            .sheet(isPresented: $showingHostPicker) {
                MobileHostPickerView(store: store)
            }
            .onDisappear {
                stopListening()
            }
        }
        .accessibilityIdentifier("MobileVoiceModeView")
    }

    @ViewBuilder
    private var targetCard: some View {
        let snapshot = store.voiceFocusSnapshot
        VStack(alignment: .leading, spacing: 8) {
            Label(
                L10n.string("mobile.voiceMode.target", defaultValue: "Target"),
                systemImage: snapshot?.isTerminal == true ? "terminal" : "exclamationmark.triangle"
            )
            .font(.headline)
            if let snapshot, snapshot.isTerminal {
                Text(snapshot.surfaceTitle ?? L10n.string("mobile.voiceMode.terminal", defaultValue: "Terminal"))
                    .font(.title3.weight(.semibold))
                if let workspaceTitle = snapshot.workspaceTitle {
                    Text(workspaceTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.string("mobile.voiceMode.noTerminalFocused", defaultValue: "No terminal focused"))
                    .font(.title3.weight(.semibold))
                Text(L10n.string("mobile.voiceMode.clickTerminal", defaultValue: "Click a terminal pane on your Mac."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("MobileVoiceModeTargetCard")
    }

    private var transcriptArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(finalTranscripts.enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !partialTranscript.isEmpty {
                    Text(partialTranscript)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.body)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .accessibilityIdentifier("MobileVoiceModeTranscript")
    }

    private var micButton: some View {
        Button {
            if isListening || isStarting {
                stopListening()
            } else {
                Task { await startListening() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isListening ? Color.red : Color.accentColor)
                    .frame(width: 104, height: 104)
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .disabled(!canStartListening && !isListening)
        .accessibilityLabel(isListening
            ? L10n.string("mobile.voiceMode.stopListening", defaultValue: "Stop Listening")
            : L10n.string("mobile.voiceMode.startListening", defaultValue: "Start Listening"))
        .accessibilityIdentifier("MobileVoiceModeMicButton")
    }

    private var canStartListening: Bool {
        store.supportsVoiceMode && store.voiceFocusSnapshot?.isTerminal == true && !isStarting
    }

    @MainActor
    private func startListening() async {
        guard canStartListening else { return }
        // A quick stop-then-start can land while the previous session is still
        // finalizing gracefully. Hard-cancel it first so two transcription
        // sessions (and their audio taps) can never be live at once.
        if session != nil || updateTask != nil {
            clearListeningSession(cancelSession: true, cancelUpdateTask: true)
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        errorMessage = nil
        sendConfirmation = nil
        isStarting = true
        let engine = voiceSettings.effectiveEngine(modelInstalled: parakeetModelStore.isInstalled)
        let permitted = await VoicePermissionRequester().requestPermissions(for: engine)
        // A stop (or a newer start) may have superseded this attempt while the
        // permission prompt was up; it must not spin up a session.
        guard generation == sessionGeneration, isStarting else { return }
        guard permitted else {
            isStarting = false
            errorMessage = L10n.string("mobile.voiceMode.permissionDenied", defaultValue: "Microphone or speech recognition permission is not available.")
            return
        }

        let session: any VoiceTranscriptionSession
        switch engine {
        case .apple:
            session = AppleVoiceTranscriptionSession()
        case .parakeetV3:
            session = ParakeetTranscriptionSession(modelDirectory: parakeetModelStore.modelDirectory)
        }
        self.session = session
        updateTask = Task { @MainActor in
            for await update in session.updates {
                handle(update)
            }
            handleUpdateStreamEnded(for: session)
        }

        nonisolated(unsafe) let capturedSession: any VoiceTranscriptionSession = session
        audioEngine.start(tapBlock: { buffer, _ in
            capturedSession.streamAudio(buffer)
        }) { started in
            Task { @MainActor in
                // A stop, failure, or newer start superseded this attempt while
                // the engine spun up off-main; its result must not flip state back.
                guard generation == sessionGeneration else { return }
                isStarting = false
                isListening = started
                if !started {
                    errorMessage = L10n.string("mobile.voiceMode.audioUnavailable", defaultValue: "The microphone could not start.")
                    stopListening()
                }
            }
        }
    }

    private func stopListening() {
        guard isListening || isStarting || session != nil else { return }
        // Invalidate any in-flight engine-ready callback for the stopped attempt.
        sessionGeneration += 1
        isListening = false
        isStarting = false
        audioEngine.stop()
        session?.finish()
    }

    private func handle(_ update: VoiceTranscriptionUpdate) {
        switch update {
        case .partial(let text):
            partialTranscript = text
        case .final(let text):
            partialTranscript = ""
            finalTranscripts.append(text)
            sendFinal(text)
        case .failed(let message):
            errorMessage = message
            clearListeningSession(cancelSession: true, cancelUpdateTask: true)
        }
    }

    private func handleUpdateStreamEnded(for endedSession: any VoiceTranscriptionSession) {
        guard let currentSession = session, currentSession === endedSession else { return }
        clearListeningSession(cancelSession: true, cancelUpdateTask: false)
    }

    private func clearListeningSession(cancelSession: Bool, cancelUpdateTask: Bool) {
        // Invalidate any in-flight engine-ready callback so it cannot set
        // `isListening` after this teardown.
        sessionGeneration += 1
        isListening = false
        isStarting = false
        partialTranscript = ""
        audioEngine.stop()
        if cancelSession {
            session?.cancel()
        }
        session = nil
        if cancelUpdateTask {
            updateTask?.cancel()
        }
        updateTask = nil
    }

    private func sendFinal(_ text: String) {
        Task { @MainActor in
            do {
                let response = try await store.sendVoiceInput(
                    text: text,
                    submit: voiceSettings.voiceModeAutoSubmit
                )
                let title = response.surfaceTitle ?? L10n.string("mobile.voiceMode.terminal", defaultValue: "Terminal")
                sendConfirmation = String(
                    format: L10n.string("mobile.voiceMode.sentToFormat", defaultValue: "Sent to %@"),
                    title
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
