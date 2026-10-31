/// R3a of the resize audit (cmux-ad, after Lawrence's P0 of 2026-10-31, "resizing terminals is broken"):
/// a visible terminal at rest has one size everywhere, grid == fit(bounds) == the PTY's == the daemon's
/// (``TerminalSizeSample/holds``). The App's `SurfaceInvariantMonitor` runs it once the layout settles
/// after a change (split, divider drag, zoom, window resize, panel show and hide, tab show), in debug
/// builds only. A mismatch counts when two checks in a row (a settle apart) see the same sizes, so a
/// grid still on its way to the daemon is not one; it is logged once (a fault in debug builds) until
/// it clears. Nothing is repaired here.
@MainActor
public final class TerminalSizeInvariant {
    /// A shown terminal: a stable key for it (its tab) and its session.
    public typealias Entry = (key: String, session: TerminalSession)

    /// Violations confirmed so far.
    public private(set) var violations = 0
    /// The last check saw a mismatch to confirm, or a terminal not at rest: check once more (at most
    /// ``maxRechecks`` times in a row, so a size that keeps changing cannot keep the checks running).
    public private(set) var wantsRecheck = false

    public init() {}

    /// Checks the shown terminals once. `action`: the newest action before the check, for the log.
    /// - Returns: The violations this check confirmed.
    @discardableResult
    public func check(_ terminals: [Entry], action: String) -> Int {
        // Red stub (R3a): compares nothing yet.
        0
    }
}
