import Foundation

/// A permission dictation needs and the user denied.
public enum DictationPermission: String, Equatable, Sendable {
    case microphone
    case speechRecognition
}

/// Where a dictation session is.
///
/// `idle` → `starting` (permission prompt, model download, audio start) →
/// `listening` → `finalizing` (flushing the last words) → `idle`. A start
/// that cannot run rests in `denied` or `failed` until the next start.
public enum DictationPhase: Equatable, Sendable {
    case idle
    case starting
    case listening
    case finalizing
    case failed(DictationFailure)
    case denied(DictationPermission)

    /// A start is allowed from here.
    public var isStartable: Bool {
        switch self {
        case .idle, .failed, .denied: true
        case .starting, .listening, .finalizing: false
        }
    }
}

/// What the composer shows after each change: the session's whole text so
/// far (committed segments then the live hypothesis), the input level while
/// listening, and whether the text was discarded.
public struct DictationUpdate: Equatable, Sendable {
    public var phase: DictationPhase
    /// The session's text: committed segments, then the volatile tail. It
    /// replaces the previous update's text in place.
    public var text: String
    /// Input level in `0...1`.
    public var level: Float
    /// The session was cancelled: the composer drops ``text``.
    public var cancelled: Bool

    public init(phase: DictationPhase, text: String = "", level: Float = 0, cancelled: Bool = false) {
        self.phase = phase
        self.text = text
        self.level = level
        self.cancelled = cancelled
    }
}
