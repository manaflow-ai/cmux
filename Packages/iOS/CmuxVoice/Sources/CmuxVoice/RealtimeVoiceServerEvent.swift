import Foundation

/// Server event subset consumed by the cmux Realtime session.
enum RealtimeVoiceServerEvent: Equatable, Sendable {
    case sessionReady
    case inputCommitted(itemID: String)
    case inputTranscriptDelta(itemID: String, delta: String)
    case inputTranscriptCompleted(itemID: String, transcript: String)
    case inputTranscriptFailed(itemID: String)
    case outputAudioDelta(itemID: String, data: Data)
    case outputAudioDone
    case outputTranscriptDelta(String)
    case outputTranscriptCompleted(String)
    case speechStarted
    case responseCreated(responseID: String)
    case responseDone(responseID: String?, calls: [RealtimeVoiceFunctionCall])
    case serviceError
    case ignored
}
