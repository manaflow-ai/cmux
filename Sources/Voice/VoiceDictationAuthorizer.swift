import CmuxVoice
import os

/// Permission checks that follow the engine picked for the session.
///
/// Speech-recognition access only matters for Apple's recognizer, so the
/// cloud and fixture engines skip it. The fixture engine (UI tests) also
/// skips the microphone, since it never records.
struct VoiceDictationAuthorizer: DictationAuthorizing {
    /// Which engine the next session uses; set on the main actor right
    /// before a session starts and read by the async permission checks.
    final class SessionEngine: @unchecked Sendable {
        enum Kind: Sendable {
            case appleSpeech
            case cloud
            case fixture
        }

        private let lock = OSAllocatedUnfairLock()
        // Guarded by `lock`.
        private var storedKind = Kind.appleSpeech

        var kind: Kind {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedKind
            }
            set {
                lock.lock()
                storedKind = newValue
                lock.unlock()
            }
        }
    }

    let sessionEngine: SessionEngine
    private let system = SystemDictationAuthorizer()

    func microphoneAuthorization() async -> DictationAuthorizationStatus {
        if sessionEngine.kind == .fixture { return .notRequired }
        return await system.microphoneAuthorization()
    }

    func requestMicrophoneAuthorization() async -> Bool {
        if sessionEngine.kind == .fixture { return true }
        return await system.requestMicrophoneAuthorization()
    }

    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus {
        guard sessionEngine.kind == .appleSpeech else { return .notRequired }
        return await system.speechRecognitionAuthorization()
    }

    func requestSpeechRecognitionAuthorization() async -> Bool {
        guard sessionEngine.kind == .appleSpeech else { return true }
        return await system.requestSpeechRecognitionAuthorization()
    }
}
