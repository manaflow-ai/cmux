/// What the composer's record button does, as Messages does it on iOS 26:
/// a tap only shows "Tap and hold to record and send audio"; a hold
/// records; lifting the finger keeps the recording going (locked) until
/// stop, which opens the review; from there "+ 0:03" records more, "x"
/// discards and send sends. VoiceOver cannot hold, so its activation
/// records straight away, locked.
///
/// `ConversationAudioComposer` feeds it touches and recorder events and
/// carries out the effects; the stage drives `ComposerAudioLayout`.
public struct ComposerAudioFlow: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// A touch too short to be a hold (or a VoiceOver activation).
        case tap(voiceOver: Bool)
        case holdBegan
        case holdEnded
        /// The microphone is running (permission granted, engine up).
        case recorderStarted
        /// Stop: `longEnough` is false for a recording Messages throws away (0.25 s or less).
        case stop(longEnough: Bool)
        case continueRecording
        /// Recording more failed to start (an audio interruption): back to the review.
        case resumeFailed
        case cancel
        case send
    }

    public enum Effect: Equatable, Sendable {
        case showHoldHint
        case startRecording
        case pauseRecording
        case resumeRecording
        case discard
        case sendRecording
    }

    /// nil while the field is a text field.
    public private(set) var stage: ComposerAudioLayout.Stage?
    /// The finger is still down on the record glyph.
    public private(set) var holding = false
    private var recorderRunning = false

    public init() {}

    public var isActive: Bool { stage != nil }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (event, stage) {
        case (.tap(let voiceOver), nil):
            guard voiceOver else { return [.showHoldHint] }
            stage = .recording
            recorderRunning = false
            return [.startRecording]
        case (.holdBegan, nil):
            stage = .holding
            holding = true
            recorderRunning = false
            return [.startRecording]
        case (.holdEnded, _):
            guard holding else { return [] }
            holding = false
            // Still waiting on the microphone: `recorderStarted` locks it.
            if stage == .holding, recorderRunning { stage = .recording }
            return []
        case (.recorderStarted, .holding?), (.recorderStarted, .recording?):
            recorderRunning = true
            if stage == .holding, !holding { stage = .recording }
            return []
        case (.stop(let longEnough), .holding?), (.stop(let longEnough), .recording?):
            guard recorderRunning else { return [] }
            holding = false
            guard longEnough else { return reset([.pauseRecording, .discard]) }
            stage = .review
            return [.pauseRecording]
        case (.continueRecording, .review?):
            stage = .recording
            return [.resumeRecording]
        case (.resumeFailed, .recording?):
            stage = .review
            return []
        case (.cancel, .some):
            return reset([.discard])
        case (.send, .review?):
            return reset([.sendRecording])
        default:
            return []
        }
    }

    private mutating func reset(_ effects: [Effect]) -> [Effect] {
        stage = nil
        holding = false
        recorderRunning = false
        return effects
    }
}
