import Foundation
import Observation

enum VoiceActivity: Equatable {
    case idle
    case connecting
    case listening
    case processing
    case executing
    case error(String)
}

@Observable
final class VoiceInputState {
    var isActive: Bool = false
    var activity: VoiceActivity = .idle
    var transcript: String = ""
    var lastAction: String = ""
    var aiReply: String = ""
}
