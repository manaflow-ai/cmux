// cmux: the message box's voice input, for the host. Not a vendored file.
import AppKit

extension MessagesLabHomeView {
    /// The message box's speech engine (held weakly; the host keeps it). Set: a mic button stands in
    /// the field's trailing slot where Messages draws its waveform; nil: the drawn waveform, no mic.
    public var voiceInput: (any HomeVoiceInput)? {
        get { controller.voice.input }
        set { controller.voice.input = newValue }
    }

    /// A change of the voice session (the host's engine): the words go into the box at the caret,
    /// the waveform follows the level, and the session's end commits or drops the words.
    public func voiceChanged(_ update: HomeVoiceUpdate) { controller.voice.apply(update) }

    /// A voice session runs in the box (Esc and Return go to it).
    public var isVoiceActive: Bool { controller.voice.isActive }

    /// The host's hooks (motion gate, tooltip); set once, before the transcript's first frame.
    public static var host = MessagesLabHomeHost()

    /// Whether Home activity loops animate: the host's ``MessagesLabHomeHost/voiceMotionGate``.
    public static var voiceMotionGate: @MainActor () -> Bool {
        get { host.voiceMotionGate }
        set { host.voiceMotionGate = newValue }
    }
}
