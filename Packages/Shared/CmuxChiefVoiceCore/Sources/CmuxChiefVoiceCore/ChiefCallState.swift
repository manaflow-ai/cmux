import Foundation

/// Where the Chief call flow is, as ``ChiefCallCoordinator/state`` reports it.
public enum ChiefCallState: Sendable, Equatable {
    /// Nothing is running.
    case idle
    /// Waiting for the user to answer the microphone prompt.
    case requestingPermission
    /// The user refused microphone access; nothing records until they allow it in Settings.
    case permissionDenied
    /// Recording since `startedAt`, for `mode`.
    case recording(mode: ChiefVoiceRequest, startedAt: Date)
    /// The recorder is stopping and the note is being saved to the outbox.
    case finishing
    /// The saved note is being transcribed on device.
    case transcribing
    /// The note is being sent to the Chief conversation.
    case sending
    /// The Chief conversation accepted the note with this id.
    case sent(UUID)
    /// The note with this id is saved in the outbox and sends when the Chief is reachable.
    case savedForLater(UUID)
    /// Recording could not start; `message` is for logs, not for display.
    case failed(String)

    /// True while a request arriving now would be ignored or would end the call.
    public var isBusy: Bool {
        switch self {
        case .requestingPermission, .recording, .finishing, .transcribing, .sending: true
        case .idle, .permissionDenied, .sent, .savedForLater, .failed: false
        }
    }
}
