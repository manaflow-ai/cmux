
/// The speech engine a ``VoiceRoomSession`` listens with: ``DictationSession`` (on device), or a
/// fake in tests.
@MainActor
public protocol VoiceRoomDictating: AnyObject {
    /// Where the engine's session is.
    var phase: DictationPhase { get }
    /// Called on every change of the session's text, level or phase.
    var onUpdate: ((DictationUpdate) -> Void)? { get set }
    /// Starts a session.
    func start()
    /// Ends the session, dropping its words.
    func cancel()
}

extension DictationSession: VoiceRoomDictating {}
