public import Foundation

/// The default engine: SpeechAnalyzer, or `SFSpeechRecognizer` restricted to
/// on-device recognition when SpeechAnalyzer has no model for the language.
/// Nothing leaves the machine and no account is needed.
///
/// The fallback asks for speech recognition permission only when it is
/// used, so the common path prompts for the microphone alone.
public actor OnDeviceDictationTranscriber: SpeechTranscribing {
    private let levelMeter: DictationAudioLevelMeter?
    private let authorizer: any DictationAuthorizing
    private var active: (any SpeechTranscribing)?
    private var isFinishing = false

    public init(levelMeter: DictationAudioLevelMeter?, authorizer: any DictationAuthorizing = SystemDictationAuthorizer()) {
        self.levelMeter = levelMeter
        self.authorizer = authorizer
    }

    public func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let analyzer = SpeechAnalyzerDictationTranscriber(levelMeter: levelMeter)
        active = analyzer
        do {
            return try await analyzer.transcribe(locale: locale)
        } catch DictationFailure.onDeviceRecognitionUnavailable {
            guard !isFinishing else { throw CancellationError() }
            try await authorizeSpeechRecognition()
            guard !isFinishing else { throw CancellationError() }
            let fallback = SFSpeechDictationTranscriber(levelMeter: levelMeter)
            active = fallback
            return try await fallback.transcribe(locale: locale)
        }
    }

    public func finishTranscribing() async {
        isFinishing = true
        await active?.finishTranscribing()
    }

    private func authorizeSpeechRecognition() async throws {
        switch await authorizer.speechRecognitionAuthorization() {
        case .authorized:
            return
        case .denied:
            throw DictationFailure.speechRecognitionAccessDenied
        case .undetermined:
            guard await authorizer.requestSpeechRecognitionAuthorization() else {
                throw DictationFailure.speechRecognitionAccessDenied
            }
        }
    }
}
