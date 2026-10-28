import Foundation

/// The words every cmux dialog shares. Callers pass their own titles,
/// lines and specific button names.
public nonisolated struct CmuxDialogStrings {
    public nonisolated init() {}
    public static var ok: String { String(localized: "dialog.ok", defaultValue: "OK", bundle: .module) }
    public static var cancel: String { String(localized: "dialog.cancel", defaultValue: "Cancel", bundle: .module) }
    /// Return, as VoiceOver names the key that presses a dialog's default button.
    public static var keyReturn: String { String(localized: "dialog.key.return", defaultValue: "Return", bundle: .module) }
    /// Escape, as VoiceOver names the key that presses a dialog's cancel button.
    public static var keyEscape: String { String(localized: "dialog.key.escape", defaultValue: "Escape", bundle: .module) }
    /// Command plus a letter ("Command-D"), as VoiceOver names a button's Command key.
    public static func keyCommand(_ letter: String) -> String {
        String(format: String(localized: "dialog.key.command", defaultValue: "Command-%@", bundle: .module), letter)
    }
    /// The line that names the web origin that asked.
    public static func from(_ origin: String) -> String {
        String(format: String(localized: "dialog.from", defaultValue: "From %@", bundle: .module), origin)
    }
}
