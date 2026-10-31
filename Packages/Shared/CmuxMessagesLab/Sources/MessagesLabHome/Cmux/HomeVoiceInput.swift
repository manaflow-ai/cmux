// cmux: the message box's voice input (the mic button). Not a vendored file.
import Foundation

/// Where the message box's words come from when the person talks: the host's
/// speech engine (cmux: on-device dictation, `HomeVoiceDictation` in
/// CmuxNextHome). The box owns the button, the waveform and where the words
/// go; the host owns the microphone, permissions and the engine, and reports
/// each change with ``MessagesLabHomeView/voiceChanged(_:)``.
public protocol HomeVoiceInput: AnyObject {
    /// The mic button: starts listening, or stops and keeps the words.
    func toggleVoice()
    /// The return-key button or Return in the box: stops and keeps the words.
    func finishVoice()
    /// Esc: stops and drops the words (the box shows its draft from before).
    func cancelVoice()
}

/// Where a voice session is, as the message box draws it.
public enum HomeVoicePhase: Equatable, Sendable {
    /// Not listening: the mic button rests in the field's trailing slot.
    case idle
    /// Asking for the microphone or starting the engine: the controls show, the waveform rests.
    case starting
    /// Hearing words: the waveform follows the input level.
    case listening
    /// Stopped; the engine flushes its last words.
    case finalizing
}

/// One change of a voice session.
public struct HomeVoiceUpdate: Equatable, Sendable {
    public var phase: HomeVoicePhase
    /// The session's words so far (committed, then the live guess). Each update replaces the last
    /// one's words in the box; the update that returns to ``HomeVoicePhase/idle`` commits them.
    public var text: String
    /// The input level in `0...1` while listening.
    public var level: Float
    /// The session was cancelled: its words leave the box.
    public var cancelled: Bool

    public init(phase: HomeVoicePhase, text: String = "", level: Float = 0, cancelled: Bool = false) {
        self.phase = phase
        self.text = text
        self.level = level
        self.cancelled = cancelled
    }
}
