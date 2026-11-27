import Foundation

/// Fit to Phone remembered per foreground program. A program the
/// person never toggled follows Settings → Terminal → Fit to Phone
/// (`CmuxMobilePreferences.terminalFitToPhone`); one they toggled from the terminal's page
/// menu keeps its own choice. Keyed by the session's `programName` ("zsh", "claude",
/// "terminal" for a shell titled with its folder).
public struct TerminalFitToPhoneMemory {
    /// One `UserDefaults` key per program: this prefix and the program's name.
    public static let keyPrefix = "cmuxMobile.terminal.fitToPhone."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether `program`'s terminal resizes the Mac to the phone (true) or the phone
    /// keeps the Mac's grid (false): its own choice when it has one, else the global setting.
    public func fitToPhone(for program: String) -> Bool {
        defaults.object(forKey: Self.key(program)) as? Bool ?? CmuxMobilePreferences.terminalFitToPhone(defaults)
    }

    /// Remembers `program`'s choice; it wins over the global setting from now on.
    public func set(_ fitToPhone: Bool, for program: String) {
        defaults.set(fitToPhone, forKey: Self.key(program))
    }

    static func key(_ program: String) -> String { keyPrefix + program }
}
