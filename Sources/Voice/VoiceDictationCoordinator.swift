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
/// Owns the controller, the insertion router, the level meter and the HUD;
/// gates every entry point on the `voice.dictationEnabled` setting; picks
/// the engine per session (on device, OpenAI, or the UI-test fixture); turns
/// the shortcut into tap-to-toggle or hold-to-talk; shows the one-time
/// "Set Up Voice" explainer before the first system permission prompt; and
/// presents recovery alerts (with System Settings deep links) when access
/// is denied or the engine fails.
@MainActor
final class VoiceDictationCoordinator {
    /// A press held at least this long counts as hold-to-talk in automatic
    /// mode; a shorter press toggles.
    static let holdThreshold: TimeInterval = 0.35

    /// UI tests set this (with `CMUX_UI_TEST_MODE=1`) to dictate a fixed
    /// script instead of recording the microphone.
    static let fixtureScriptEnvironmentKey = "CMUX_UI_TEST_VOICE_FIXTURE_SCRIPT"

    private let catalog: SettingCatalog
    private let defaults: UserDefaults
    private let controller: DictationController
    private let levelMeter: DictationAudioLevelMeter
    private let sessionEngine: VoiceDictationAuthorizer.SessionEngine
    private let apiKeyStore: VoiceDictationAPIKeyStore
    private let fixtureScript: String?
    private let insertionRouter: VoiceDictationInsertionRouter
    private lazy var hud = VoiceDictationHUDController(
        controller: controller,
        levelMeter: levelMeter,
        usesCloudEngine: { [weak self] in self?.sessionEngine.kind == .cloud },
        stopAction: { [weak self] in self?.stopFromHUD() }
    )
    private var defaultsObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var tabBarButtonAvailable: Bool
    private var hold: HoldTracking?

    /// The shortcut press currently deciding between toggle and hold.
    private struct HoldTracking {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let pressedAt: TimeInterval
        let mode: VoiceDictationHotkeyMode
        let monitor: Any
    }

    init(
        catalog: SettingCatalog,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        apiKeyStore: VoiceDictationAPIKeyStore = VoiceDictationAPIKeyStore(),
        focusedTerminalTarget: @escaping @MainActor () -> VoiceDictationTerminalTarget?
    ) {
        self.catalog = catalog
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        let fixtureScript = environment["CMUX_UI_TEST_MODE"] == "1"
            ? environment[Self.fixtureScriptEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
            : nil
        self.fixtureScript = fixtureScript
        let levelMeter = DictationAudioLevelMeter()
        self.levelMeter = levelMeter
        let sessionEngine = VoiceDictationAuthorizer.SessionEngine()
        self.sessionEngine = sessionEngine
        let cleanupKey = catalog.voice.cleanUpAgentPrompts
        let languageKey = catalog.voice.dictationLanguage
        let dictationLocale: @MainActor @Sendable () -> Locale = { [defaults] in
            let identifier = languageKey.value(in: defaults)
            return identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
        }
        let router = VoiceDictationInsertionRouter(
            focusedTerminalTarget: focusedTerminalTarget,
            cleanUpAgentPrompts: { [defaults] in
                cleanupKey.value(in: defaults) && dictationLocale().supportsDictationFillerCleanup
            }
        )
        insertionRouter = router
        let transcriberProvider = SystemSpeechTranscriberProvider()
        let modelKey = catalog.voice.openAIModel
        let controller = DictationController(
            authorizer: VoiceDictationAuthorizer(sessionEngine: sessionEngine),
            inserter: router,
            makeTranscriber: { [defaults] in
                switch sessionEngine.kind {
                case .fixture:
                    return FixtureDictationTranscriber(script: fixtureScript ?? "", levelMeter: levelMeter)
                case .cloud:
                    let model = modelKey.value(in: defaults).trimmingCharacters(in: .whitespaces)
                    return CloudDictationTranscriber(
                        client: OpenAITranscriptionClient(
                            apiKey: apiKeyStore.apiKey() ?? "",
                            model: model.isEmpty ? OpenAITranscriptionClient.defaultModel : model
                        ),
                        levelMeter: levelMeter
                    )
                case .appleSpeech:
                    return transcriberProvider.makeTranscriber(levelMeter: levelMeter)
                }
            },
            localeProvider: dictationLocale
        )
        self.controller = controller
        tabBarButtonAvailable = Self.showsTabBarButton(catalog: catalog, defaults: defaults)
        controller.failureHandler = { [weak self] failure in
            self?.presentFailure(failure)
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.defaultsDidChange()
            }
        }
        // Holding the shortcut while switching apps hides the key-up from
        // the local monitor; end hold-to-talk there instead of recording on.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationDidResignActive()
            }
        }
        hud.activate()
    }

    deinit {
        for observer in [defaultsObserver, resignActiveObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Whether the surface tab bar should show the mic button.
    static func showsTabBarButton(catalog: SettingCatalog, defaults: UserDefaults) -> Bool {
        catalog.voice.dictationEnabled.value(in: defaults)
            && catalog.voice.showTabBarButton.value(in: defaults)
    }

    /// Handles a key-down of the Toggle Voice Dictation shortcut.
    ///
    /// A quick press toggles. In automatic mode a press held past
    /// ``holdThreshold`` dictates until the shortcut is released; in hold
    /// mode every press does.
    ///
    /// - Returns: `true` when the press was consumed (the feature is
    ///   enabled or a session is running), `false` when dictation is off in
    ///   Settings and the event should continue through the responder chain.
    @discardableResult
    func handleShortcut(_ event: NSEvent) -> Bool {
        if event.isARepeat {
            // Auto-repeat while the shortcut is held belongs to the press
            // already being handled.
            return controller.isActiveOrStarting || hold != nil
        }
        if controller.isActiveOrStarting {
            endHoldTracking()
            controller.stop()
            return true
        }
        guard catalog.voice.dictationEnabled.value(in: defaults) else { return false }
        let mode = catalog.voice.hotkeyMode.value(in: defaults)
        guard startSession() else { return true }
        if mode != .toggle {
            beginHoldTracking(event, mode: mode)
        }
        return true
    }

    /// Handles the mic button and the command palette entry: always a
    /// toggle, since there is no key to hold.
    ///
    /// - Returns: `false` when dictation is disabled in Settings.
    @discardableResult
    func toggleFromUI() -> Bool {
        if controller.isActiveOrStarting {
            controller.stop()
            return true
        }
        guard catalog.voice.dictationEnabled.value(in: defaults) else { return false }
        startSession()
        return true
    }

    /// Handles a UI action that already resolved the pane it was clicked in.
    @discardableResult
    func toggleFromUI(target: VoiceDictationTerminalTarget) -> Bool {
        if controller.isActiveOrStarting {
            controller.stop()
            return true
        }
        guard catalog.voice.dictationEnabled.value(in: defaults) else { return false }
        startSession(explicitTerminalTarget: target)
        return true
    }

    /// Stops an active session from the HUD through the same coordinator-owned
    /// action path used by the keyboard shortcut.
    func stopFromHUD() {
        guard controller.isActiveOrStarting else { return }
        endHoldTracking()
        controller.stop()
    }

    /// Starts a session, or shows what is missing first.
    ///
    /// - Returns: Whether a session is starting.
    @discardableResult
    private func startSession(
        explicitTerminalTarget: VoiceDictationTerminalTarget? = nil
    ) -> Bool {
        let engine = catalog.voice.engine.value(in: defaults)
        if fixtureScript != nil {
            sessionEngine.kind = .fixture
        } else if engine == .openAI {
            guard apiKeyStore.hasAPIKey else {
                presentFailure(.cloudCredentialMissing)
                return false
            }
            sessionEngine.kind = .cloud
        } else {
            sessionEngine.kind = .appleSpeech
        }
        guard fixtureScript != nil || catalog.voice.dictationSetupCompleted.value(in: defaults) else {
            presentSetupDialog()
            return false
        }
        if let explicitTerminalTarget {
            insertionRouter.setNextExplicitTerminalTarget(explicitTerminalTarget)
        }
        controller.start()
        return true
    }

    private func beginHoldTracking(_ event: NSEvent, mode: VoiceDictationHotkeyMode) {
        endHoldTracking()
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleHoldEvent(event)
        }
        guard let monitor else { return }
        hold = HoldTracking(
            keyCode: keyCode,
            modifiers: modifiers,
            pressedAt: event.timestamp,
            mode: mode,
            monitor: monitor
        )
    }

    /// Watches for the shortcut's release while a press is being tracked.
    private func handleHoldEvent(_ event: NSEvent) -> NSEvent? {
        guard let hold else { return event }
        let released: Bool
        let consume: Bool
        switch event.type {
        case .keyUp:
            released = event.keyCode == hold.keyCode
            // The key-down never reached the terminal, so its key-up must
            // not either (kitty keyboard protocol apps would see a release).
            consume = released
        case .flagsChanged:
            released = !event.modifierFlags.intersection(hold.modifiers).isSuperset(of: hold.modifiers)
            consume = false
        default:
            released = false
            consume = false
        }
        guard released else { return event }
        let heldFor = event.timestamp - hold.pressedAt
        endHoldTracking()
        let isHoldToTalk = hold.mode == .hold || heldFor >= Self.holdThreshold
        if isHoldToTalk, controller.isActiveOrStarting {
            controller.stop()
        }
        return consume ? nil : event
    }

    private func applicationDidResignActive() {
        guard hold != nil else { return }
        endHoldTracking()
        controller.stop()
    }

    private func endHoldTracking() {
        guard let hold else { return }
        NSEvent.removeMonitor(hold.monitor)
        self.hold = nil
    }

    private func defaultsDidChange() {
        let available = Self.showsTabBarButton(catalog: catalog, defaults: defaults)
        if available != tabBarButtonAvailable {
            tabBarButtonAvailable = available
            AppDelegate.shared?.reapplyVoiceDictationTabBarButtons()
        }
        guard controller.isActiveOrStarting,
              !catalog.voice.dictationEnabled.value(in: defaults) else { return }
        endHoldTracking()
        controller.stop()
    }

    private func presentSetupDialog() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "voice.setup.title",
            defaultValue: "Voice Dictation is here"
        )
        alert.informativeText = String(
            localized: "voice.setup.message",
            defaultValue: "Speak into the focused pane and cmux pastes what you say. With the default engine, speech is transcribed on this Mac and no audio leaves the device. macOS will ask for microphone access (and speech recognition on older versions) when you continue."
        )
        alert.addButton(withTitle: String(
            localized: "voice.setup.confirm",
            defaultValue: "Set Up Voice"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runCmuxModal() == .alertFirstButtonReturn else { return }
        catalog.voice.dictationSetupCompleted.set(true, in: defaults)
        startSession()
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
                        defaultValue: "On-device speech recognition does not support “%@” on this Mac. Pick another language in Settings › Voice, or switch the engine to OpenAI."
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
        case .cloudCredentialMissing:
            presentInfoAlert(
                message: String(
                    localized: "voice.error.cloudKeyMissing.title",
                    defaultValue: "Add an OpenAI API key"
                ),
                informative: String(
                    localized: "voice.error.cloudKeyMissing.message",
                    defaultValue: "The OpenAI dictation engine needs your API key. Add it in Settings › Voice, or switch the engine back to On This Mac."
                )
            )
        case .cloudTranscriptionFailed(let detail):
            voiceDictationLogger.error(
                "Voice dictation cloud transcription failed: \(detail, privacy: .private)"
            )
            presentInfoAlert(
                message: String(
                    localized: "voice.error.cloudTranscription.title",
                    defaultValue: "OpenAI couldn’t transcribe that"
                ),
                informative: String(
                    localized: "voice.error.cloudTranscription.message",
                    defaultValue: "The request to OpenAI failed. Check your connection and API key in Settings › Voice, then try again."
                )
            )
        case .transcriptionFailed(let detail) where sessionEngine.kind == .cloud:
            // A cloud stop timeout; the on-device copy below would wrongly
            // say audio stayed on this Mac.
            presentFailure(.cloudTranscriptionFailed(detail))
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
