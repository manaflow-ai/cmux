public import CmuxNextDictation
public import CmuxNextPages
public import CmuxNextSettings
import AppKit
import CmuxNextCompat

/// The Messages page's mic (the native Home's HomeVoiceDictation, moved behind the page): the
/// composer's mic button, its keys and Esc call `dictation {method, params}` (`dictation.toggle`,
/// `.start`, `.stop`, `.cancel`, `.openSettings {permission}`; `.audio` is taken and ignored: Home
/// sends words, never audio), and each change of the session goes to the page on the `dictation`
/// stream as the agent pane's update (`{state, text, level, cancelled, message?, permission?,
/// settingsLabel?}`), which the page splices at the composer's caret (agent-session dictation.ts).
///
/// One microphone across the app: starting here stops an agent pane's session (keeping its words)
/// and the other way round (``DictationMicrophoneClaims``). Between sessions nothing runs; the
/// engine is made on first use.
@MainActor
public final class HomePageDictation {
    /// The page's updates (pushed; idle until a session runs).
    public let stream = HomePageStream(initial: .null)
    private let claims: DictationMicrophoneClaims
    private let makeSession: @MainActor () -> DictationSession
    private var session: DictationSession?
    /// Opens a URL (System Settings); tests record it.
    var open: (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }

    public init(claims: DictationMicrophoneClaims = .shared, makeSession: @escaping @MainActor () -> DictationSession = HomePageDictation.systemSession) {
        self.claims = claims
        self.makeSession = makeSession
    }

    /// The on-device engine. Debug builds hear a recorded clip instead when
    /// `CMUX_NEXT_DICTATION_AUDIO_FILE` names one (machines without a microphone).
    public static func systemSession() -> DictationSession {
        #if DEBUG
        if let recorded = DictationSession.recorded() { return recorded }
        #endif
        return DictationSession()
    }

    /// One call from the page; throws for a method it does not know.
    public func call(_ params: JSONValue) throws -> JSONValue {
        switch params["method"]?.stringValue ?? "" {
        case "dictation.toggle":
            let session = active()
            if session.phase.isStartable { claims.claim(self) { [weak self] in self?.session?.stop() } }
            session.toggle()
        case "dictation.start":
            let session = active()
            guard session.phase.isStartable else { break }
            claims.claim(self) { [weak self] in self?.session?.stop() }
            session.start()
        case "dictation.stop": session?.stop()
        case "dictation.cancel": session?.cancel()
        case "dictation.audio": break
        case "dictation.openSettings":
            let permission = params["params"]?["permission"]?.stringValue.flatMap(DictationPermission.init(rawValue:))
            if let url = permission.flatMap(Self.settingsURL) { open(url) }
        case let method: throw PageError.unknownOp(method)
        }
        return .null
    }

    /// The page went away: any session ends and drops its words.
    public func close() {
        session?.cancel()
        session?.onUpdate = nil
        claims.release(self)
    }

    private func active() -> DictationSession {
        if let session { return session }
        let made = makeSession()
        made.onUpdate = { [weak self] update in self?.deliver(update) }
        session = made
        return made
    }

    func deliver(_ update: DictationUpdate) {
        if update.phase.isStartable { claims.release(self) }
        stream.publish(Self.payload(update))
    }

    /// The page's update (the agent pane's `AgentDictationUpdate`, without audio).
    static func payload(_ update: DictationUpdate) -> JSONValue {
        var value: [String: JSONValue] = [
            "text": .string(update.text), "level": .number((Double(update.level) * 1000).rounded() / 1000), "cancelled": .bool(update.cancelled),
        ]
        switch update.phase {
        case .idle: value["state"] = "idle"
        case .starting: value["state"] = "starting"
        case .listening: value["state"] = "listening"
        case .finalizing: value["state"] = "finalizing"
        case .failed(let failure):
            value["state"] = "failed"
            value["message"] = .string(failureMessage(failure))
        case .denied(let permission):
            value["state"] = "denied"
            value["permission"] = .string(permission.rawValue)
            value["message"] = .string(deniedMessage(permission))
            value["settingsLabel"] = .string(openSettingsTitle)
        }
        return .object(value)
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
