import Foundation

/// The words every cmux dialog shares. Callers pass their own titles,
/// lines and specific button names.
public nonisolated struct CmuxDialogStrings {
    public nonisolated init() {}
    public static var ok: String { String(localized: "dialog.ok", defaultValue: "OK", bundle: .module) }
    public static var cancel: String { String(localized: "dialog.cancel", defaultValue: "Cancel", bundle: .module) }
    /// The line that names the web origin that asked.
    public static func from(_ origin: String) -> String {
        String(format: String(localized: "dialog.from", defaultValue: "From %@", bundle: .module), origin)
    }
}
