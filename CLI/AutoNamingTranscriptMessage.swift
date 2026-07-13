import Foundation

/// One user/assistant text message extracted from a transcript.
struct AutoNamingTranscriptMessage: Codable, Equatable, Sendable {
    var role: String
    var text: String
}
