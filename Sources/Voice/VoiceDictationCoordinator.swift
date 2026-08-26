import AppKit
import CmuxSettings
import CmuxVoice
import os

nonisolated private let voiceDictationLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "VoiceDictation"
)

/// App-side composition and user flow around `DictationController`.
///
/// Owns the controller, the insertion router, and the HUD; gates the
/// shortcut on the `voice.dictationEnabled` setting; shows the one-time
/// "Set Up Voice" explainer before the first system permission prompt; and
/// presents recovery alerts (with System Settings deep links) when access
/// is denied or the engine fails.
@MainActor
final class VoiceDictationCoordinator {
    private let catalog: SettingCatalog
    private let defaults: UserDefaults
    private let controller: DictationController
    private let hud: VoiceDictationHUDController

    init(
        catalog: SettingCatalog,
        defaults: UserDefaults = .standard,
        focusedTerminalPanel: @escaping () -> TerminalPanel?
    ) {
        self.catalog = catalog
        self.defaults = defaults
        let router = VoiceDictationInsertionRouter(focusedTerminalPanel: focusedTerminalPanel)
        let transcriberProvider = SystemSpeechTranscriberProvider()
        let languageKey = catalog.voice.dictationLanguage
        let controller = DictationController(
            authorizer: SystemDictationAuthorizer(),
            inserter: router,
            makeTranscriber: { transcriberProvider.makeTranscriber() },
            localeProvider: { [defaults] in
                let identifier = languageKey.value(in: defaults)
                return identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
            }
        )
        self.controller = controller
        self.hud = VoiceDictationHUDController(controller: controller)
        controller.failureHandler = { [weak self] failure in
            self?.presentFailure(failure)
        }
        hud.activate()
    }

    /// Handles the Toggle Voice Dictation shortcut.
    ///
    /// - Returns: `true` when the press was consumed (the feature is
    ///   enabled), `false` when dictation is disabled in Settings and the
    ///   event should continue through the responder chain.
    @discardableResult
    func handleShortcutToggle() -> Bool {
        if controller.isActive {
            controller.stop()
            return true
        }
        guard catalog.voice.dictationEnabled.value(in: defaults) else { return false }
        guard catalog.voice.dictationSetupCompleted.value(in: defaults) else {
            presentSetupDialog()
            return true
        }
        controller.start()
        return true
    }

    private func presentSetupDialog() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "voice.setup.title",
            defaultValue: "Voice Dictation is here"
        )
        alert.informativeText = String(
            localized: "voice.setup.message",
            defaultValue: "Speak into the focused pane and cmux types what you say. Speech is transcribed entirely on this Mac — no audio or text ever leaves the device. macOS will ask for microphone access (and speech recognition on older versions) when you continue."
        )
        alert.addButton(withTitle: String(
            localized: "voice.setup.confirm",
            defaultValue: "Set Up Voice"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runCmuxModal() == .alertFirstButtonReturn else { return }
        catalog.voice.dictationSetupCompleted.set(true, in: defaults)
        controller.start()
    }

    private func presentFailure(_ failure: DictationFailure) {
        switch failure {
        case .insertionTargetUnavailable:
            // Focus was nowhere insertable; a modal would be heavier than
            // the miss deserves.
            NSSound.beep()
        case .microphoneAccessDenied:
            presentAccessDeniedAlert(
                message: String(
                    localized: "voice.error.micDenied.title",
                    defaultValue: "Microphone access is off"
                ),
                informative: String(
                    localized: "voice.error.micDenied.message",
                    defaultValue: "Voice dictation needs the microphone. Allow cmux under Privacy & Security › Microphone in System Settings."
                ),
                settingsPane: "Privacy_Microphone"
            )
        case .speechRecognitionAccessDenied:
            presentAccessDeniedAlert(
                message: String(
                    localized: "voice.error.speechDenied.title",
                    defaultValue: "Speech recognition access is off"
                ),
                informative: String(
                    localized: "voice.error.speechDenied.message",
                    defaultValue: "Voice dictation needs speech recognition. Allow cmux under Privacy & Security › Speech Recognition in System Settings."
                ),
                settingsPane: "Privacy_SpeechRecognition"
            )
        case .onDeviceRecognitionUnavailable(let localeIdentifier):
            presentInfoAlert(
                message: String(
                    localized: "voice.error.localeUnavailable.title",
                    defaultValue: "Language not available for dictation"
                ),
                informative: String.localizedStringWithFormat(
                    String(
                        localized: "voice.error.localeUnavailable.message",
                        defaultValue: "On-device speech recognition does not support “%@” on this Mac. Pick another language in Settings › Voice. cmux never sends audio to a server."
                    ),
                    localeIdentifier
                )
            )
        case .modelDownloadFailed(let detail):
            voiceDictationLogger.error(
                "Voice dictation model download failed: \(detail, privacy: .private)"
            )
            presentInfoAlert(
                message: String(
                    localized: "voice.error.modelDownload.title",
                    defaultValue: "Couldn’t download the speech model"
                ),
                informative: String(
                    localized: "voice.error.modelDownload.message",
                    defaultValue: "cmux couldn’t prepare the on-device speech model. Check your connection and try again. Audio and transcripts stay on this Mac."
                )
            )
        case .audioCaptureFailed(let detail):
            voiceDictationLogger.error(
                "Voice dictation audio capture failed: \(detail, privacy: .private)"
            )
            presentInfoAlert(
                message: String(
                    localized: "voice.error.audioCapture.title",
                    defaultValue: "Couldn’t start the microphone"
                ),
                informative: String(
                    localized: "voice.error.audioCapture.message",
                    defaultValue: "cmux couldn’t start audio capture. Check that an input device is connected, then try again."
                )
            )
        case .transcriptionFailed(let detail):
            voiceDictationLogger.error(
                "Voice dictation transcription failed: \(detail, privacy: .private)"
            )
            presentInfoAlert(
                message: String(
                    localized: "voice.error.transcription.title",
                    defaultValue: "Dictation stopped unexpectedly"
                ),
                informative: String(
                    localized: "voice.error.transcription.message",
                    defaultValue: "Voice dictation stopped unexpectedly. Try again. Audio and transcripts stay on this Mac."
                )
            )
        }
    }

    private func presentAccessDeniedAlert(
        message: String,
        informative: String,
        settingsPane: String
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: String(
            localized: "voice.error.openSystemSettings",
            defaultValue: "Open System Settings"
        ))
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        guard alert.runCmuxModal() == .alertFirstButtonReturn else { return }
        let url = "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)"
        if let settingsURL = URL(string: url) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private func presentInfoAlert(message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal()
    }
}
