/// What an entry point (Action Button, Siri, Shortcuts, Control Center) asks for.
///
/// Both requests record the user at once and end as a voice note in the
/// Chief conversation; they differ only in the screen title and in the note's
/// ``VoiceNote/mode``.
public enum ChiefVoiceRequest: String, Sendable, Codable, Hashable, CaseIterable {
    /// A call with the user's Chief (the Action Button default).
    case call
    /// A voice note for the Chief, with no call framing.
    case voiceNote
}
