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
    #if DEBUG
    private var recordedInput: URL?

    /// Debug builds: hears a recorded clip instead of the microphone
    /// (``RecordedDictationInput``), with no permission to ask for.
    public init(levelMeter: DictationAudioLevelMeter?, recordedInput url: URL) {
        self.levelMeter = levelMeter
        self.authorizer = RecordedInputAuthorizer()
        self.recordedInput = url
    }
    #endif

    public init(levelMeter: DictationAudioLevelMeter?, authorizer: any DictationAuthorizing = SystemDictationAuthorizer()) {
        self.levelMeter = levelMeter
        self.authorizer = authorizer
    }

    public func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let analyzer = SpeechAnalyzerDictationTranscriber(levelMeter: levelMeter)
        #if DEBUG
        if let recordedInput { await analyzer.hear(recordedInput) }
        #endif
        active = analyzer
        do {
            return try await analyzer.transcribe(locale: locale)
        } catch DictationFailure.onDeviceRecognitionUnavailable {
            guard !isFinishing else { throw CancellationError() }
            #if DEBUG
            // The fallback engine listens to the live microphone: a recorded
            // clip fails here instead of quietly dictating from the mic.
            if recordedInput != nil { throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier) }
            #endif
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
