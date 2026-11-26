import Foundation

/// Turns a recorded file into text. The iOS adapter uses on-device `SFSpeechRecognizer`.
public protocol VoiceTranscribing: Sendable {
    /// Transcribes the audio at `url`.
    /// - Returns: The transcript, possibly empty when nothing was said.
    /// - Throws: When recognition is unavailable or not authorized.
    func transcribe(fileAt url: URL) async throws -> String
}
