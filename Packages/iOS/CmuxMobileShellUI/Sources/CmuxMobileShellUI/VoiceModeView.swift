#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileSupport
import CmuxVoice
import SwiftUI

/// Full-screen iPhone microphone mode for sending transcribed speech to the focused Mac terminal.
struct VoiceModeView: View {
    @Environment(VoiceSettingsStore.self) private var voiceSettings
    @Environment(VoiceVocabularyStore.self) private var voiceVocabulary
    @Environment(ParakeetModelCatalogStore.self) private var modelCatalog
    @Environment(ParakeetVocabularyBoostStore.self) private var vocabularyBoostStore
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
    @State private var utteranceHistory = VoiceUtteranceHistory()
    @State private var errorMessage: String?
    @State private var showingHostPicker = false
    @State private var typedText = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        @Bindable var voiceSettings = voiceSettings
        return NavigationStack {
            VStack(spacing: isTextFieldFocused ? 12 : 24) {
                targetCard
                transcriptArea
                Spacer(minLength: isTextFieldFocused ? 0 : 8)
                micButton
                    .scaleEffect(isTextFieldFocused ? 0.72 : 1)
                    .frame(height: isTextFieldFocused ? 76 : 104)
                Toggle(isOn: $voiceSettings.voiceModeAutoSubmit) {
                    Text(L10n.string("mobile.voiceMode.autoSubmit", defaultValue: "Auto-submit"))
                }
                .accessibilityIdentifier("MobileVoiceModeAutoSubmit")
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("MobileVoiceModeError")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, isTextFieldFocused ? 8 : 16)
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
                        // `onDisappear` hard-cancels the session; no graceful
                        // stop here, so dismissal can never leave work behind.
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                textInputRow
            }
            .onDisappear {
                // Leaving the screen is a hard cancel, not a graceful stop: a
                // graceful finish waits on the recognizer's final result, so a
                // stalled recognizer would keep the unstructured update task and
                // the ASR/CoreML session retained past the view lifetime.
                // Dropping the unfinalized tail on navigation matches composer
                // dictation's navigation semantics.
                clearListeningSession(cancelSession: true, cancelUpdateTask: true)
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
                if let layout = snapshot.layout {
                    VoiceFocusLayoutView(layout: layout)
                    VStack(alignment: .leading, spacing: 2) {
                        if let workspaceTitle = snapshot.workspaceTitle {
                            Text(workspaceTitle)
                                .foregroundStyle(.secondary)
                        }
                        Text(snapshot.surfaceTitle ?? L10n.string("mobile.voiceMode.terminal", defaultValue: "Terminal"))
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                } else {
                    Text(snapshot.surfaceTitle ?? L10n.string("mobile.voiceMode.terminal", defaultValue: "Terminal"))
                        .font(.title3.weight(.semibold))
                    if let workspaceTitle = snapshot.workspaceTitle {
                        Text(workspaceTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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
                ForEach(utteranceHistory.utterances) { utterance in
                    VoiceUtteranceRow(utterance: utterance) {
                        resendUtterance(id: utterance.id)
                    }
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
        .frame(maxWidth: .infinity, minHeight: isTextFieldFocused ? 72 : 180)
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
        // Keep the button tappable while starting: the action path treats a tap
        // during `isStarting` as cancel, so disabling it there would leave the
        // user with no way to abort a hung permission prompt or engine spin-up.
        .disabled(!hasVoiceTarget && !isListening && !isStarting)
        .accessibilityLabel(isListening
            ? L10n.string("mobile.voiceMode.stopListening", defaultValue: "Stop Listening")
            : L10n.string("mobile.voiceMode.startListening", defaultValue: "Start Listening"))
        .accessibilityIdentifier("MobileVoiceModeMicButton")
    }

    private var textInputRow: some View {
        HStack(spacing: 10) {
            TextField(
                L10n.string("mobile.voiceMode.textPlaceholder", defaultValue: "Type or dictate…"),
                text: $typedText
            )
            .focused($isTextFieldFocused)
            .submitLabel(.send)
            .onSubmit(sendTypedText)
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityIdentifier("MobileVoiceModeTextField")

            Button {
                sendTypedText()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(!canSendTypedText)
            .foregroundStyle(canSendTypedText ? Color.accentColor : Color.secondary)
            .accessibilityLabel(L10n.string("mobile.voiceMode.sendText", defaultValue: "Send"))
            .accessibilityIdentifier("MobileVoiceModeSendButton")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    /// Whether the Mac currently offers a valid Voice Mode target, independent
    /// of this view's own start-in-progress state.
    private var hasVoiceTarget: Bool {
        store.supportsVoiceMode && store.voiceFocusSnapshot?.isTerminal == true
    }

    private var canStartListening: Bool {
        hasVoiceTarget && !isStarting
    }

    private var canSendTypedText: Bool {
        hasVoiceTarget && !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        isStarting = true
        let engine = voiceSettings.effectiveEngine(installedEngines: modelCatalog.installedEngineIDs)
        let vocabularyTerms = voiceVocabulary.recognitionTerms(
            screenStrings: Self.screenVocabularyStrings(from: store.voiceFocusSnapshot)
        )
        let permitted = await VoicePermissionRequester().requestPermissions(for: engine)
        // A stop (or a newer start) may have superseded this attempt while the
        // permission prompt was up; it must not spin up a session.
        guard generation == sessionGeneration, isStarting else { return }
        // The focus target can also change while the prompt is up (Mac focus
        // moved off a terminal, host switched, capabilities dropped); starting
        // anyway would record against no valid target.
        guard hasVoiceTarget else {
            isStarting = false
            return
        }
        guard permitted else {
            isStarting = false
            errorMessage = L10n.string("mobile.voiceMode.permissionDenied", defaultValue: "Microphone or speech recognition permission is not available.")
            return
        }

        let session: any VoiceTranscriptionSession
        switch engine {
        case .apple:
            session = AppleVoiceTranscriptionSession(contextualStrings: vocabularyTerms)
        case .parakeetV3, .parakeetV3Int4, .parakeetV2:
            guard let modelStore = modelCatalog.store(for: engine) else {
                isStarting = false
                errorMessage = L10n.string("mobile.voiceMode.audioUnavailable", defaultValue: "The microphone could not start.")
                return
            }
            session = ParakeetTranscriptionSession(
                modelStore: modelStore,
                vocabularyTerms: vocabularyTerms,
                vocabularyBoostDirectory: vocabularyBoostStore.installedDirectoryForRecognition
            )
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
            let id = utteranceHistory.appendFinal(text: text)
            sendUtterance(id: id, text: text)
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

    private func resendUtterance(id: VoiceUtterance.ID) {
        guard let utterance = utteranceHistory.utterance(id: id),
              utteranceHistory.beginSending(id: id) else {
            return
        }
        sendUtterance(id: id, text: utterance.text)
    }

    private func sendTypedText() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasVoiceTarget, !text.isEmpty else { return }
        typedText = ""
        let id = utteranceHistory.appendFinal(text: text)
        sendUtterance(id: id, text: text)
    }

    private func sendUtterance(id: VoiceUtterance.ID, text: String) {
        let expectedFocusSnapshot = store.voiceFocusSnapshot
        Task { @MainActor in
            do {
                let response = try await store.sendVoiceInput(
                    text: text,
                    submit: voiceSettings.voiceModeAutoSubmit,
                    expectedFocusSnapshot: expectedFocusSnapshot
                )
                let title = response.surfaceTitle ?? L10n.string("mobile.voiceMode.terminal", defaultValue: "Terminal")
                utteranceHistory.markSent(id: id, targetTitle: title)
                errorMessage = nil
            } catch {
                utteranceHistory.markFailed(
                    id: id,
                    message: Self.sendErrorMessage(error),
                    isTargetChanged: Self.isTargetChanged(error)
                )
            }
        }
    }

    /// User-facing copy for a failed voice send. Mac-authored RPC and auth
    /// messages are already localized UI copy and pass through; anything else
    /// (transport, decode) is internal detail and maps to generic copy.
    private static func sendErrorMessage(_ error: any Error) -> String {
        if let connectionError = error as? MobileShellConnectionError {
            switch connectionError {
            case .rpcError(let code, let message):
                if code == "target_changed" {
                    return L10n.string(
                        "mobile.voiceMode.targetChanged",
                        defaultValue: "The focused pane changed. Check the target and speak again."
                    )
                }
                return message
            case .authorizationFailed(let message),
                 .accountMismatch(let message):
                return message
            default:
                break
            }
        }
        return L10n.string(
            "mobile.voiceMode.sendFailed",
            defaultValue: "Couldn't send to the Mac. Check the connection and try again."
        )
    }

    private static func isTargetChanged(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError,
              case .rpcError(let code, _) = connectionError else {
            return false
        }
        return code == "target_changed"
    }

    private static func screenVocabularyStrings(from snapshot: MobileFocusSnapshot?) -> [String] {
        guard let snapshot else { return [] }
        var values = [String]()
        if let workspaceTitle = snapshot.workspaceTitle {
            values.append(workspaceTitle)
        }
        if let surfaceTitle = snapshot.surfaceTitle {
            values.append(surfaceTitle)
        }
        if let layout = snapshot.layout {
            values.append(contentsOf: layout.panes.compactMap(\.title))
        }
        return values
    }
}
#endif
