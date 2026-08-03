#if os(iOS)
import Foundation

/// A recognition event produced by a composer dictation backend.
public enum ComposerDictationRecognitionUpdate: Sendable {
    /// A transcript update. `isFinal` means recognition completed with this text.
    case transcript(String, isFinal: Bool)
    /// Recognition completed without a usable transcript.
    case finished
    /// Recognition failed or the stream ended with an error.
    case failed
}
#endif
