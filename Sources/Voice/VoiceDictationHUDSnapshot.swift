import CmuxVoice

/// Value-only presentation state projected by the dictation HUD bridge.
struct VoiceDictationHUDSnapshot: Equatable, Sendable {
    let phase: DictationPhase
    let transcriptTail: String
}
