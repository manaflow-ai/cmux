#if os(iOS)
@preconcurrency public import AVFoundation
public import CmuxMobileSupport
public import Foundation

/// Composer-dictation backend that feeds microphone buffers to a Parakeet session.
@MainActor
public final class ParakeetComposerDictationRecognitionBackend: ComposerDictationRecognitionBackend {
    private let makeSession: @MainActor () -> any VoiceTranscriptionSession
    private var session: (any VoiceTranscriptionSession)?
    private var updateTask: Task<Void, Never>?

    /// Creates a composer backend for an installed Parakeet model.
    /// - Parameter modelDirectory: The downloaded model directory.
    public convenience init(modelDirectory: URL) {
        self.init(makeSession: { ParakeetTranscriptionSession(modelDirectory: modelDirectory) })
    }

    /// Creates a composer backend with an injected session factory.
    /// - Parameter makeSession: Factory used for each dictation start.
    public init(makeSession: @escaping @MainActor () -> any VoiceTranscriptionSession) {
        self.makeSession = makeSession
    }

    /// Parakeet support is decided by the composition root before this backend is selected.
    public var isSupported: Bool { true }

    /// Parakeet availability is decided by the composition root before this backend is selected.
    public var isAvailable: Bool { true }

    /// Parakeet requires only microphone permission.
    public nonisolated func resolvedAuthorization() -> ComposerDictationAuthorizationResolution {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .granted
            case .denied:
                return .denied
            case .undetermined:
                return .undetermined
            @unknown default:
                return .undetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                return .granted
            case .denied:
                return .denied
            case .undetermined:
                return .undetermined
            @unknown default:
                return .undetermined
            }
        }
    }

    /// Requests microphone permission without touching Speech authorization.
    public nonisolated func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        }
    }

    /// Builds the audio tap that feeds the Parakeet session.
    public func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let session = makeSession()
        self.session = session
        nonisolated(unsafe) let tapSession = session
        return { buffer, _ in
            tapSession.streamAudio(buffer)
        }
    }

    /// Starts forwarding recognition updates to the composer controller.
    public func start(resultHandler: @escaping @MainActor (ComposerDictationRecognitionUpdate) -> Void) {
        guard let session else {
            resultHandler(.failed)
            return
        }
        updateTask = Task { @MainActor in
            for await update in session.updates {
                switch update {
                case .partial(let text):
                    resultHandler(.transcript(text, isFinal: false))
                case .final(let text):
                    resultHandler(.transcript(text, isFinal: true))
                case .failed:
                    resultHandler(.failed)
                }
            }
        }
    }

    /// Signals that no more audio will arrive.
    public func endAudio() {
        session?.finish()
    }

    /// Cancels recognition immediately.
    public func cancel() {
        updateTask?.cancel()
        updateTask = nil
        session?.cancel()
        session = nil
    }
}
#endif
