import Foundation

/// The user-tunable depth of the phone's local terminal scrollback, shared by
/// the writer (the iOS Settings screen) and the readers (the shell composite's
/// hydration request and the Mac's replay clamp) so the three can never drift.
///
/// The value is the number of history rows a screen-anchored replay hydrates
/// when the mirror has none (cold attach, rebuilt surface). Deeper values
/// scroll further back at the cost of a proportionally larger one-time
/// download at connect (~250 bytes per row); the visible screen never waits
/// on it.
public enum MobileTerminalScrollbackPreference {
    /// UserDefaults key, written by Settings and read at hydration time.
    public static let defaultsKey = "cmux.mobile.terminalScrollbackRows"

    /// The depths Settings offers.
    public static let choices = [1000, 4000, 10000, 20000]

    /// Default depth when nothing is stored.
    public static let defaultRows = MobileTerminalRenderGridFrame.screenAnchorScrollbackRowBudget

    /// Hard ceiling both sides clamp to. Bounded by the 8 MiB transport frame
    /// cap (~250 bytes of JSON per row leaves comfortable headroom at 20k).
    public static let maximumRows = 20000

    /// Clamps an arbitrary stored or requested value to the supported range.
    public static func clamped(_ rows: Int) -> Int {
        min(max(rows, 0), maximumRows)
    }

    /// The effective depth from `defaults`, falling back to ``defaultRows``.
    public static func resolve(from defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: defaultsKey) as? Int else {
            return defaultRows
        }
        return clamped(stored)
    }
}
