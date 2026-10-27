import AppKit
import CmuxNextCompat
import CmuxNextDictation
import CmuxNextWakeups
import MessagesLabHome

/// The speech engine behind Home's mic. The system engine (``DictationSession``: SpeechAnalyzer on
/// macOS 26 and newer, SFSpeechRecognizer before, on device) is the default.
///
/// Hook: a later OpenAI realtime voice upsell is another conformance here, chosen where
/// ``HomeVoiceDictation`` is made (`makeEngine`); the message box and its controls stay as they are.
@MainActor
protocol HomeDictationEngine: AnyObject {
    var phase: DictationPhase { get }
    var onUpdate: ((DictationUpdate) -> Void)? { get set }
    func toggle()
    func stop()
    func cancel()
}

extension DictationSession: HomeDictationEngine {}

/// Home's message box dictation (``HomeVoiceInput``): the mic button starts and stops a session of
/// the on-device engine, its words stream into the box, Esc drops them. One microphone across the
/// app: starting here stops an agent pane's session (keeping its words) and the other way round
/// (``DictationMicrophoneClaims``). Between sessions nothing runs; the engine is made on first use.
/// A denied permission shows the box's notice with Open System Settings.
@MainActor
final class HomeVoiceDictation: HomeVoiceInput {
    weak var view: HomeNativeTranscriptView?
    private let makeEngine: () -> any HomeDictationEngine
    private let claims: DictationMicrophoneClaims
    private var engine: (any HomeDictationEngine)?
    /// Opens a URL (System Settings); tests record it.
    var open: (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }

    /// - Parameters:
    ///   - deadlines: The app's deadline scheduler (`AppServices.mainDeadlines`), which the system engine's session
    ///     runs on (its stop deadline and its events).
    ///   - claims: The app's one microphone.
    ///   - makeEngine: Makes the engine on first use; nil makes the system engine.
    init(deadlines: MainDeadlineScheduler, claims: DictationMicrophoneClaims = .shared,
         makeEngine: (() -> any HomeDictationEngine)? = nil) {
        self.claims = claims
        self.makeEngine = makeEngine ?? { HomeVoiceDictation.systemEngine(deadlines: deadlines) }
    }

    /// The on-device engine. Debug builds hear a recorded clip instead when
    /// `CMUX_NEXT_DICTATION_AUDIO_FILE` names one (machines without a microphone).
    static func systemEngine(deadlines: MainDeadlineScheduler) -> any HomeDictationEngine {
        #if DEBUG
        if let recorded = DictationSession.recorded(deadlines: deadlines) { return recorded }
        #endif
        return DictationSession(deadlines: deadlines)
    }

    var phase: DictationPhase { engine?.phase ?? .idle }

    func toggleVoice() {
        let engine = activeEngine()
        if engine.phase.isStartable {
            claims.claim(self) { [weak self] in self?.engine?.stop() }
            view?.showNotice(nil)
        }
        engine.toggle()
    }

    func finishVoice() { engine?.stop() }

    func cancelVoice() { engine?.cancel() }

    /// The view closed: drop any session and its words.
    func close() {
        engine?.cancel()
        engine?.onUpdate = nil
        claims.release(self)
    }

    private func activeEngine() -> any HomeDictationEngine {
        if let engine { return engine }
        let made = makeEngine()
        made.onUpdate = { [weak self] update in self?.deliver(update) }
        engine = made
        return made
    }

    func deliver(_ update: DictationUpdate) {
        if update.phase.isStartable { claims.release(self) }
        view?.transcript.voiceChanged(Self.boxUpdate(update))
        switch update.phase {
        case .denied(let permission):
            view?.showNotice(Self.deniedMessage(permission), action: HomeNoticeAction(title: Self.openSettingsTitle) { [weak self] in
                if let url = Self.settingsURL(permission) { self?.open(url) }
            })
        case .failed(let failure):
            view?.showNotice(Self.failureMessage(failure))
        default:
            break
        }
    }

    /// What the box draws for an engine update: a failed or denied session ends like a stop (the
    /// words heard so far stay).
    static func boxUpdate(_ update: DictationUpdate) -> HomeVoiceUpdate {
        let phase: HomeVoicePhase = switch update.phase {
        case .idle, .failed, .denied: .idle
        case .starting: .starting
        case .listening: .listening
        case .finalizing: .finalizing
        }
        return HomeVoiceUpdate(phase: phase, text: update.text, level: update.level, cancelled: update.cancelled)
    }

    /// The Privacy & Security pane for `permission`.
    static func settingsURL(_ permission: DictationPermission) -> URL? {
        let anchor = switch permission {
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    static func deniedMessage(_ permission: DictationPermission) -> String {
        switch permission {
        case .microphone:
            String(localized: "home.voice.microphoneDenied", defaultValue: "Dictation needs microphone access. Turn it on for cmux in System Settings.", bundle: .module)
        case .speechRecognition:
            String(localized: "home.voice.speechDenied", defaultValue: "Dictation in this language needs speech recognition. Turn it on for cmux in System Settings.", bundle: .module)
        }
    }

    static var openSettingsTitle: String {
        String(localized: "home.voice.openSettings", defaultValue: "Open System Settings", bundle: .module)
    }

    static func failureMessage(_ failure: DictationFailure) -> String {
        switch failure {
        case .onDeviceRecognitionUnavailable:
            String(localized: "home.voice.languageUnavailable", defaultValue: "On-device dictation is not available for this language.", bundle: .module)
        case .modelDownloadFailed:
            String(localized: "home.voice.modelDownloadFailed", defaultValue: "The speech model could not be downloaded. Try again when you are online.", bundle: .module)
        case .audioCaptureFailed:
            String(localized: "home.voice.noMicrophone", defaultValue: "No microphone is available.", bundle: .module)
        case .microphoneAccessDenied, .speechRecognitionAccessDenied, .transcriptionFailed:
            String(localized: "home.voice.failed", defaultValue: "Dictation stopped unexpectedly.", bundle: .module)
        }
    }
}

/// A notice's one action (Open System Settings beside "Dictation needs microphone access").
struct HomeNoticeAction {
    let title: String
    let run: () -> Void
}
