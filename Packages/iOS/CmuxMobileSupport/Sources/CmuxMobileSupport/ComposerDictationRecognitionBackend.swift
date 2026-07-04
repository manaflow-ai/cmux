#if os(iOS)
@preconcurrency public import AVFoundation

/// Recognition backend used by ``ComposerDictationController``.
@MainActor
public protocol ComposerDictationRecognitionBackend: AnyObject {
    /// Whether this backend can ever run on the current device/locale.
    var isSupported: Bool { get }

    /// Whether this backend can start right now.
    var isAvailable: Bool { get }

    /// Current permission state for this backend's required recognizers.
    nonisolated func resolvedAuthorization() -> ComposerDictationAuthorizationResolution

    /// Requests the permissions required by this backend.
    /// - Parameter completion: Receives `true` when the backend can start.
    nonisolated func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void)

    /// Builds the audio tap closure that receives microphone buffers.
    /// - Returns: A sendable tap closure installed on the shared audio engine.
    func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    /// Starts recognition after the audio engine reports that capture is running.
    /// - Parameter resultHandler: Receives recognition updates on the main actor.
    func start(resultHandler: @escaping @MainActor (ComposerDictationRecognitionUpdate) -> Void)

    /// Flushes buffered audio for a graceful stop.
    func endAudio()

    /// Cancels recognition immediately.
    func cancel()
}

/// Synchronous authorization verdict for a dictation backend.
public enum ComposerDictationAuthorizationResolution: Sendable {
    /// All required permissions are granted.
    case granted
    /// At least one required permission is denied or restricted.
    case denied
    /// At least one required permission has not been requested yet.
    case undetermined
}
#endif
