public import AVFoundation
import Foundation

/// Where a recorded engine's microphone audio comes from
/// (``RecordedDictationTranscriber``). ``MicrophoneDictationCapture`` is the
/// device; tests feed scripted buffers.
public protocol DictationAudioCapturing: Sendable {
    /// Opens the input and hands every buffer to `onBuffer`, on the audio
    /// thread. `onFailure` reports a capture that broke after it started (a
    /// device that went away and could not be reopened).
    ///
    /// - Throws: ``DictationFailure/audioCaptureFailed(_:)`` when there is no
    ///   input to open.
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (DictationFailure) async -> Void
    ) async throws

    /// Closes the input and releases the microphone. Safe to call at any
    /// time, more than once.
    func stop() async
}

/// The default input device (``DictationInputTap``): the same capture
/// ``SFSpeechDictationTranscriber`` does, reopened when the device or its
/// format changes.
public actor MicrophoneDictationCapture: DictationAudioCapturing {
    private let tap = DictationInputTap()

    public init() {}

    public func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (DictationFailure) async -> Void
    ) async throws {
        do {
            try tap.start(onBuffer: onBuffer, onFailure: onFailure)
        } catch {
            throw error as? DictationFailure ?? DictationFailure.audioCaptureFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        tap.stop()
    }
}
