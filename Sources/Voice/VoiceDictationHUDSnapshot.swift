import CmuxVoice

/// Value-only presentation state projected by the dictation HUD bridge.
struct VoiceDictationHUDSnapshot: Equatable, Sendable {
    let phase: DictationPhase
    let transcriptTail: String
    /// The cloud engine shows no partials and transcribes on stop, so the
    /// HUD says "Transcribing…" instead of "Finishing…".
    let usesCloudEngine: Bool
}
