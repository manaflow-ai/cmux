import AppKit
public import CmuxNextDictation
import Foundation
import CmuxNextCompat
import CmuxNextInput
import CmuxNextWakeups

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
/// with the pane; between sessions nothing runs (no engine, audio tap, level
/// stream, input subscription or observer). Each change goes to the page as
/// `cmuxAcpmuxBridge.dictation(update)`, which splices the text at the
/// composer's cursor.
///
/// One microphone at a time: starting in one pane stops the other pane's
/// session, keeping its text.
final class AgentPaneDictation {
    private let microphone: DictationMicrophone
    private let makeSession: () -> DictationSession
    private var session: DictationSession?
    /// Delivers an update to the page (an event on the page host).
    private let send: (DictationUpdate) -> Void
    /// The app's input tap: a hold-to-talk hears its release here.
    private let input: InputEventTap
    /// The chat's harness takes voice input (``AgentPaneDictationCommand/recordAudio(_:)``), so
    /// every start, from the mic, its shortcut, the palette or the CLI, keeps the session's audio.
    private var recordsAudio = false
    /// Opens a URL (System Settings).
    var open: (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }
    /// A session started (`true`: starting, listening or finalizing) or ended (`false`), once per
    /// change and once more at ``close()`` if one still ran: the page's `dictation` keep reason, so
    /// a hidden chat is not frozen or discarded while it still takes the person's words.
    var onRunning: ((Bool) -> Void)?
    private var running = false

    /// The held shortcut while hold-to-talk may still apply: a press that
    /// lasts longer than ``holdThreshold`` stops on release; a quick press
    /// leaves dictation running until the next press.
    private var held: (keyCode: UInt16, chord: NSEvent.ModifierFlags, pressedAt: TimeInterval)?
    /// Hears the held key's release (key-ups and modifier changes, in every window: the release goes
    /// to whichever window is key), only while a hold is armed.
    private var releaseWatch: InputSubscription?
    /// Ends the hold when the app loses focus: the release goes elsewhere.
    private var resignObserver: EventSubscription?
    /// Stops the session when the Mac sleeps; observed only while a session runs.
    private var sleepObserver: EventSubscription?
    /// The app's notice fan-outs: the app's resign (`appEvents`) and the Mac's sleep (`workspaceEvents`), one
    /// observer per notice for the whole app (tests make their own centers and post to them).
    private let mainThread: AgentPaneMainThread
    /// The event clock (`NSEvent.timestamp`'s), for telling a fresh key press from a stale one.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    static let holdThreshold: TimeInterval = 0.35

    /// - Parameters:
    ///   - mainThread: The app's main-thread scheduling; its deadlines run the default session (its stop deadline
    ///     and its events), and its notices end a hold and stop on sleep.
    ///   - makeSession: Makes the session on first use; nil makes the on-device one.
    init(
        input: InputEventTap,
        mainThread: AgentPaneMainThread,
        send: @escaping (DictationUpdate) -> Void,
        microphone: DictationMicrophone = .shared,
        makeSession: (() -> DictationSession)? = nil
    ) {
        self.input = input
        self.mainThread = mainThread
        self.send = send
        self.microphone = microphone
        self.makeSession = makeSession ?? { AgentPaneDictation.defaultSession(deadlines: mainThread.deadlines) }
    }

    var phase: DictationPhase { session?.phase ?? .idle }

    /// The on-device engine. Debug builds hear a recorded clip instead when
    /// `CMUX_NEXT_DICTATION_AUDIO_FILE` names one (machines without a microphone).
    static func defaultSession(deadlines: MainDeadlineScheduler) -> DictationSession {
        #if DEBUG
        if let recorded = DictationSession.recorded(deadlines: deadlines) { return recorded }
        #endif
        return DictationSession(deadlines: deadlines)
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
        releaseWatch = input.subscribe(class: [.key, .flags]) { [weak self] event in
            switch event.type {
            case .flagsChanged: self?.flagsChanged(event)
            case .keyUp: self?.keyUp(event)
            default: break
            }
        }
        resignObserver = mainThread.appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "AgentPaneDictation.hold") { [weak self] in
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
        releaseWatch?.cancel()
        releaseWatch = nil
        resignObserver = nil
    }

    /// The pane closed: drop any session and its text.
    func close() {
        endHold()
        endSleepWatch()
        session?.cancel()
        session?.onUpdate = nil
        noteRunning(false)
    }

    private func noteRunning(_ now: Bool) {
        guard now != running else { return }
        running = now
        onRunning?(now)
    }

    /// Whether anything is still armed for a session (tests check nothing leaks).
    var holdsResources: Bool {
        releaseWatch != nil || resignObserver != nil || sleepObserver != nil || session?.holdsResources == true
    }

    private func start() {
        if let other = microphone.listening, other !== self { other.session?.stop() }
        microphone.listening = self
        // Home's message box listening stops first (one microphone across surfaces).
        microphone.claims?.claim(self) { [weak self] in self?.session?.stop() }
        let session = activeSession()
        session.recordsAudio = recordsAudio
        session.start()
        noteRunning(!phase.isStartable)
        if !phase.isStartable, sleepObserver == nil {
            sleepObserver = mainThread.workspaceEvents.subscribe(NSWorkspace.willSleepNotification, owner: "AgentPaneDictation.sleep") { [weak self] in
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
        made.onUpdate = { [weak self] update in self?.deliver(update) }
        session = made
        return made
    }

    private func deliver(_ update: DictationUpdate) {
        noteRunning(!update.phase.isStartable)
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
        if let audio = update.audio {
            value["audio"] = ["mimeType": "audio/wav", "data": audio.base64EncodedString()] as [String: any Sendable]
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

    /// The Privacy & Security pane for `permission`.
    static func settingsURL(_ permission: DictationPermission) -> URL? {
        let anchor = switch permission {
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}
