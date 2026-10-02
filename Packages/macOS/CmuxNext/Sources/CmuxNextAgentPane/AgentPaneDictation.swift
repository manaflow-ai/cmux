import AppKit
public import CmuxNextDictation
import Foundation

/// A dictation request from the page's mic button or keys.
public nonisolated enum AgentPaneDictationCommand: Equatable, Sendable {
    case toggle
    case start
    case stop
    /// Esc: end the session and drop its text.
    case cancel
    /// The denied state's link: the System Settings privacy pane.
    case openSettings(DictationPermission)
}

/// One agent pane's dictation. The session is made on first use and lives
/// with the pane; between sessions nothing runs (no engine, tap, level
/// stream or monitor). Each change goes to the page as
/// `cmuxAcpmuxBridge.dictation(update)`, which splices the text at the
/// composer's cursor.
///
/// One microphone at a time: starting in one pane stops the other pane's
/// session, keeping its text.
final class AgentPaneDictation {
    /// The pane that listens now, if any.
    private static weak var listening: AgentPaneDictation?

    private let makeSession: () -> DictationSession
    private var session: DictationSession?
    /// Delivers a script to the page.
    private let evaluate: (String) -> Void
    /// Opens a URL (System Settings).
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The held shortcut's key while hold-to-talk may still apply: a press
    /// that lasts longer than ``holdThreshold`` stops on release; a quick
    /// press leaves dictation running until the next press.
    private var held: (keyCode: UInt16, pressedAt: TimeInterval)?
    private var keyUpMonitor: Any?
    static let holdThreshold: TimeInterval = 0.35

    init(evaluate: @escaping (String) -> Void, makeSession: @escaping () -> DictationSession = { DictationSession() }) {
        self.evaluate = evaluate
        self.makeSession = makeSession
    }

    var phase: DictationPhase { session?.phase ?? .idle }

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
        }
    }

    /// The Toggle Dictation shortcut. A press starts or stops; holding the
    /// key past ``holdThreshold`` makes it push-to-talk, stopping on
    /// release. Key repeats while held do nothing.
    func toggle(from event: NSEvent?) {
        if let event, event.type == .keyDown, event.isARepeat { return }
        let starting = phase.isStartable
        handle(.toggle)
        guard starting, let event, event.type == .keyDown, !phase.isStartable else { return }
        endHold()
        held = (event.keyCode, event.timestamp)
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.keyUp(event)
            return event
        }
    }

    private func keyUp(_ event: NSEvent) {
        guard let held, event.keyCode == held.keyCode else { return }
        let duration = event.timestamp - held.pressedAt
        endHold()
        if duration >= Self.holdThreshold { session?.stop() }
    }

    private func endHold() {
        held = nil
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        keyUpMonitor = nil
    }

    /// The pane closed: drop any session and its text.
    func close() {
        endHold()
        session?.cancel()
        session?.onUpdate = nil
    }

    private func start() {
        if let other = Self.listening, other !== self { other.session?.stop() }
        Self.listening = self
        activeSession().start()
    }

    private func activeSession() -> DictationSession {
        if let session { return session }
        let made = makeSession()
        made.onUpdate = { [weak self] update in self?.deliver(update) }
        session = made
        return made
    }

    private func deliver(_ update: DictationUpdate) {
        if update.phase.isStartable {
            endHold()
            if Self.listening === self { Self.listening = nil }
        }
        guard let script = Self.script(update) else { return }
        evaluate(script)
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
