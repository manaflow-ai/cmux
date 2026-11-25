import Foundation

/// The programs a projecting phone fits at once (Rust `fit_policy`, through
/// `TerminalFitPolicy`): once the person typed into htop, vim or Codex on
/// this phone, the next time it is in the foreground the phone claims its
/// grid before the first frame, on every terminal. Most recent last; the
/// policy bounds it (64).
@MainActor
public enum TerminalFitMemory {
    static let key = "cmuxMobile.terminalFitPrograms"

    public static var programs: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Forgets every program (tests and demos start clean).
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
