import Foundation
import Observation

/// Runs one Chief call or voice note from request to delivery.
@MainActor
@Observable
public final class ChiefCallCoordinator {
    /// The current step of the flow.
    public private(set) var state: ChiefCallState = .idle

    private let recorder: any VoiceRecording
    private let transcriber: any VoiceTranscribing
    private let microphone: any MicrophoneAuthorizing
    private let delivery: any ChiefVoiceDelivering
    private let outbox: VoiceNoteOutbox
    private let now: @Sendable () -> Date

    /// Creates a coordinator.
    public init(recorder: any VoiceRecording, transcriber: any VoiceTranscribing,
                microphone: any MicrophoneAuthorizing, delivery: any ChiefVoiceDelivering,
                outbox: VoiceNoteOutbox, now: @escaping @Sendable () -> Date = { Date() }) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.microphone = microphone
        self.delivery = delivery
        self.outbox = outbox
        self.now = now
    }

    /// Handles a request from an entry point.
    public func handle(_ request: ChiefVoiceRequest) async {}

    /// Ends the running call.
    public func end() async {}

    /// Ends the running call because the audio session was interrupted.
    public func interrupted() async {}

    /// Retries every saved note.
    public func drainOutbox() async {}
}
