import os

/// Signpost events for the burst bench (scripts/cmux-next/burst-bench.py), subsystem
/// `com.cmuxterm.app.next`, category `burst`: a refusal the person saw, a terminal grid sent to
/// its PTY, and that terminal's first output after it (the TUI's redraw at the new size). The bench
/// streams them with the action signposts and times each against the press before it (both on the
/// mach clock). Emitting costs one enabled check while nothing streams. No stored state: each
/// owner holds its own value.
public struct BurstSignposts: Sendable {
    private let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "burst")

    /// The events.
    public init() {}

    /// A refusal the person sees (the HUD).
    public func refusal() {
        signposter.emitEvent("refusal")
    }

    /// A grid of `cols` x `rows` went to the PTY of `surface`.
    public func ptyGrid(surface: UInt64, cols: Int, rows: Int) {
        signposter.emitEvent("pty-grid", "surface=\(surface, privacy: .public) cols=\(cols, privacy: .public) rows=\(rows, privacy: .public)")
    }

    /// The first output of `surface` after a grid went to its PTY.
    public func firstOutput(surface: UInt64) {
        signposter.emitEvent("first-output", "surface=\(surface, privacy: .public)")
    }
}
