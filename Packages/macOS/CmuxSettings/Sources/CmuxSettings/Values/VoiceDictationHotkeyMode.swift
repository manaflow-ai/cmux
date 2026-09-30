/// How the dictation shortcut behaves (`voice.hotkeyMode`).
public enum VoiceDictationHotkeyMode: String, CaseIterable, Sendable, SettingCodable {
    /// A quick press toggles dictation; holding the shortcut dictates until
    /// it is released.
    case automatic
    /// Every press toggles dictation on or off.
    case toggle
    /// Dictation runs only while the shortcut is held.
    case hold
}
