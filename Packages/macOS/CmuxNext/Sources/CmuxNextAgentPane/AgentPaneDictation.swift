import AppKit
public import CmuxNextDictation
import Foundation
import CmuxNextCompat

/// A dictation request from the page's mic button or keys.
public nonisolated enum AgentPaneDictationCommand: Equatable, Sendable {
    case toggle
    case start
    case stop
    /// Esc: end the session and drop its text.
    case cancel
    /// The denied state's link: the System Settings privacy pane.
    case openSettings(DictationPermission)
    /// Whether the chat's harness takes voice input (ACP `promptCapabilities.audio`): sessions
    /// started from then on keep their audio for the prompt. The page says so whenever it changes.
    case recordAudio(Bool)
}

/// The microphone the agent panes share: at most one listens at a time.
final class DictationMicrophone {
    static let shared = DictationMicrophone(claims: .shared)
    /// The pane that listens now, if any.
    weak var listening: AgentPaneDictation?
    /// The app-wide claim the panes share with Home's message box (nil: panes only, tests).
    let claims: DictationMicrophoneClaims?

    init(claims: DictationMicrophoneClaims? = nil) {
        self.claims = claims
    }

    /// Stops whichever pane listens, keeping its words. False when none does.
    @discardableResult
    func stopListening() -> Bool {
        guard let listening, !listening.phase.isStartable else { return false }
        listening.handle(.stop)
        return true
    }
}

/// One agent pane's dictation. The session is made on first use and lives
/// with the pane; between sessions nothing runs (no engine, tap, level
/// stream, monitor or observer). Each change goes to the page as
/// `cmuxAcpmuxBridge.dictation(update)`, which splices the text at the
/// composer's cursor.
///
/// One microphone at a time: starting in one pane stops the other pane's
/// session, keeping its text.
final class AgentPaneDictation {
    private let microphone: DictationMicrophone
    private let makeSession: () -> DictationSession
    private var session: DictationSession?
    /// Delivers an update to the page (a script on the old host, an event on the page host).
    private let send: (DictationUpdate) -> Void
    /// The chat's harness takes voice input (``AgentPaneDictationCommand/recordAudio(_:)``), so
    /// every start, from the mic, its shortcut, the palette or the CLI, keeps the session's audio.
    private var recordsAudio = false
    /// A fresh folder for a long recording (``AgentPaneModel/onDictationFolder``); nil: temporary.
    var recordingFolder: () -> URL? = { nil }
    /// Capture the chat at start: closing the recording may outlive a pane navigation.
    var chatSession: () -> String? = { nil }
    private var recordingChat = ""
    /// The long recordings this pane's sessions wrote and handed the page, newest last, each with
    /// the chat it was made in and the file the writer left there: the only files
    /// ``takeRecording(_:session:)`` gives out, so the page can never have the host send any other
    /// file (not even one put at that path since).
    private var issued: [(recording: AgentPaneIssuedRecording, session: String)] = []
    /// How many recordings ``issued`` keeps: the page asks for one as its session ends.
    static let issuedRecordingLimit = 8
    /// Opens a URL (System Settings).
    var open: (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }

    /// The held shortcut while hold-to-talk may still apply: a press that
    /// lasts longer than ``holdThreshold`` stops on release; a quick press
    /// leaves dictation running until the next press.
    private var held: (keyCode: UInt16, chord: NSEvent.ModifierFlags, pressedAt: TimeInterval)?
    private var keyUpMonitor: Any?
    /// Ends the hold when the app loses focus: the release goes elsewhere.
    private var resignObserver: MainActorObservation?
    /// Stops the session when the Mac sleeps; observed only while a session runs.
    private var sleepObserver: MainActorObservation?
    /// Where sleep is announced (tests post their own).
    var sleepNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    /// The event clock (`NSEvent.timestamp`'s), for telling a fresh key press from a stale one.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    static let holdThreshold: TimeInterval = 0.35

    init(
        send: @escaping (DictationUpdate) -> Void,
        microphone: DictationMicrophone = .shared,
        makeSession: @escaping () -> DictationSession = { AgentPaneDictation.defaultSession() }
    ) {
        self.send = send
        self.microphone = microphone
        self.makeSession = makeSession
    }

    /// The old host: each update is a script the page runs.
    convenience init(
        evaluate: @escaping (String) -> Void,
        microphone: DictationMicrophone = .shared,
        makeSession: @escaping () -> DictationSession = { AgentPaneDictation.defaultSession() }
    ) {
        self.init(send: { update in
            if let script = Self.script(update) { evaluate(script) }
        }, microphone: microphone, makeSession: makeSession)
    }

    var phase: DictationPhase { session?.phase ?? .idle }

    /// The on-device engine. Debug builds hear a recorded clip instead when
    /// `CMUX_NEXT_DICTATION_AUDIO_FILE` names one (machines without a microphone).
    static func defaultSession() -> DictationSession {
        #if DEBUG
        if let recorded = DictationSession.recorded() { return recorded }
        #endif
        return DictationSession()
    }

    func handle(_ command: AgentPaneDictationCommand) {
        switch command {
        case .toggle:
            if phase.isStartable { start() } else { activeSession().stop() }
        case .start:
            start()
        case .stop:
            session?.stop()
        case .cancel:
            session?.cancel()
        case .openSettings(let permission):
            if let url = Self.settingsURL(permission) { open(url) }
        case .recordAudio(let on):
            recordsAudio = on
        }
    }

    /// Toggle Dictation. From its shortcut, a press starts or stops; holding
    /// the key past ``holdThreshold`` makes it push-to-talk, stopping on
    /// release. Key repeats while held do nothing. Any other event (the
    /// palette's Return, a stale one behind a menu or CLI call) is a plain toggle.
    func toggle(from event: NSEvent?) {
        let press = shortcutPress(event)
        if press?.isARepeat == true { return }
        let starting = phase.isStartable
        handle(.toggle)
        guard starting, let press, !phase.isStartable else { return }
        endHold()
        held = (press.keyCode, Self.chord(press.modifierFlags), press.timestamp)
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged { self?.flagsChanged(event) } else { self?.keyUp(event) }
            return event
        }
        resignObserver = MainActorObservation(NSApplication.didResignActiveNotification) { [weak self] in
            self?.endHold()
        }
    }

    /// A key-down that is a modifier chord pressed just now, or nil.
    private func shortcutPress(_ event: NSEvent?) -> NSEvent? {
        guard let event, event.type == .keyDown, !Self.chord(event.modifierFlags).isEmpty,
              now() - event.timestamp < 0.5 else { return nil }
        return event
    }

    private static func chord(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .control, .option])
    }

    /// The key came up with the chord still down: the release.
    func keyUp(_ event: NSEvent) {
        guard let held, event.keyCode == held.keyCode else { return }
        // A plain key-up while the hold is armed means the chord's own
        // release went elsewhere (a prompt, another app): a later "v" typed
        // in the composer, not push-to-talk ending.
        release(at: event.timestamp, stops: Self.chord(event.modifierFlags).isSuperset(of: held.chord))
    }

    /// A modifier of the chord came up before the key: that is the release.
    func flagsChanged(_ event: NSEvent) {
        guard let held, !Self.chord(event.modifierFlags).isSuperset(of: held.chord) else { return }
        release(at: event.timestamp, stops: true)
    }

    private func release(at time: TimeInterval, stops: Bool) {
        guard let held else { return }
        endHold()
        if stops, time - held.pressedAt >= Self.holdThreshold { session?.stop() }
    }

    private func endHold() {
        held = nil
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        keyUpMonitor = nil
        resignObserver = nil
    }

    /// The pane closed: drop any session and its text.
    func close() {
        endHold()
        endSleepWatch()
        session?.cancel()
        session?.onUpdate = nil
    }

    /// Whether anything is still armed for a session (tests check nothing leaks).
    var holdsResources: Bool {
        keyUpMonitor != nil || resignObserver != nil || sleepObserver != nil || session?.holdsResources == true
    }

    private func start() {
        if let other = microphone.listening, other !== self { other.session?.stop() }
        microphone.listening = self
        // Home's message box listening stops first (one microphone across surfaces).
        microphone.claims?.claim(self) { [weak self] in self?.session?.stop() }
        let session = activeSession()
        session.recordsAudio = recordsAudio
        if session.phase.isStartable { recordingChat = chatSession() ?? "" }
        session.start()
        if !phase.isStartable, sleepObserver == nil {
            sleepObserver = MainActorObservation(NSWorkspace.willSleepNotification, center: sleepNotifications) { [weak self] in
                self?.session?.stop()
            }
        }
    }

    private func endSleepWatch() {
        sleepObserver = nil
    }

    private func activeSession() -> DictationSession {
        if let session { return session }
        let made = makeSession()
        made.onUpdate = { [weak self] update in
            guard let self else { return }
            self.deliver(update, recordedIn: self.recordingChat)
        }
        made.recordingFolder = { [weak self] in self?.recordingFolder() }
        session = made
        return made
    }

    /// Long recording `path`, when this pane's dictation wrote it in chat `session` and handed it to
    /// the page; taken once (`dictation.recording.upload`, ``AgentPaneDictationUpload``).
    func takeRecording(_ path: String, session: String) -> AgentPaneIssuedRecording? {
        guard let index = issued.firstIndex(where: { $0.recording.file.path == path && $0.session == session }) else { return nil }
        return issued.remove(at: index).recording
    }

    /// Gives back long `recording` of chat `session` whose upload failed, so the page's Retry
    /// can take it again (``takeRecording(_:session:)``, still once per try).
    func giveBackRecording(_ recording: AgentPaneIssuedRecording, session: String) {
        issue(recording, session: session)
    }

    private func issue(_ recording: AgentPaneIssuedRecording, session: String) {
        issued.append((recording, session))
        if issued.count > Self.issuedRecordingLimit { issued.removeFirst(issued.count - Self.issuedRecordingLimit) }
    }

    /// One of the session's updates, for the page, named for `chat`, the chat its session was
    /// started in (``recordingChat``), whatever the pane shows now. A long recording on it is
    /// issued to that chat.
    func deliver(_ update: DictationUpdate, recordedIn chat: String) {
        var update = update
        update.chat = chat
        if let file = update.audio?.file, let identity = update.audio?.fileIdentity {
            issue(AgentPaneIssuedRecording(file: file, identity: identity), session: chat)
        }
        if update.phase.isStartable {
            endHold()
            endSleepWatch()
            if microphone.listening === self { microphone.listening = nil }
            microphone.claims?.release(self)
        }
        send(update)
    }

    // MARK: - Page payload

    /// The page's `AgentDictationUpdate`.
    static func payload(_ update: DictationUpdate) -> [String: any Sendable] {
        var value: [String: any Sendable] = [
            "state": state(update.phase),
            "text": update.text,
            "level": (Double(update.level) * 1000).rounded() / 1000,
            "cancelled": update.cancelled,
        ]
        if let chat = update.chat { value["session"] = chat }
        switch update.phase {
        case .denied(let permission):
            value["permission"] = permission.rawValue
            value["message"] = deniedMessage(permission)
            value["settingsLabel"] = openSettingsTitle
        case .failed(let failure):
            value["message"] = failureMessage(failure)
        default:
            break
        }
        // A recording that fits a prompt goes as its bytes (an audio block); a longer one as the
        // file it was written to, which the composer attaches as a saved original.
        if let audio = update.audio {
            var sent: [String: any Sendable] = ["mimeType": "audio/wav", "byteCount": audio.byteCount]
            if let data = audio.data { sent["data"] = data.base64EncodedString() }
            if let file = audio.file { sent["path"] = file.path }
            value["audio"] = sent
        }
        if let omitted = update.audioOmitted {
            value["audioOmitted"] = omitted.rawValue
        }
        return value
    }

    static func state(_ phase: DictationPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .starting: "starting"
        case .listening: "listening"
        case .finalizing: "finalizing"
        case .failed: "failed"
        case .denied: "denied"
        }
    }

    static func script(_ update: DictationUpdate) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload(update), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.cmuxAcpmuxBridge?.dictation?.(\(json));"
    }

    /// The Privacy & Security pane for `permission`.
    static func settingsURL(_ permission: DictationPermission) -> URL? {
        let anchor = switch permission {
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}
