/// Makes one dictation session's engine in place of On This Mac (Labs > Parakeet Dictation,
/// `labs.parakeetDictation`, docs/design/voice-byo-providers.md slice 3).
///
/// The app sets ``DictationMicrophoneClaims/engine``; ``DictationSession``'s default engine
/// hands it to ``OnDeviceDictationTranscriber``, so every surface follows the choice at its
/// next start. `nil`, the default, keeps On This Mac.
public typealias DictationEngineFactory = @Sendable (DictationAudioLevelMeter?) -> any SpeechTranscribing
