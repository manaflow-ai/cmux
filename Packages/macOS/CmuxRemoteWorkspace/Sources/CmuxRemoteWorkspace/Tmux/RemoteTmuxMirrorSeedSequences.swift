import Foundation

/// Pure escape-sequence constants plus the capture-paint builder used to seed a
/// mirror surface from a remote tmux pane.
///
/// These are the exact terminal byte streams ``RemoteTmuxControlConnection``
/// emits to a mirror surface while (re)seeding it: the alternate-screen
/// enter/exit sequences, the reconnect re-seed clear, and the capture-pane
/// repaint. They hold no mutable state and touch no actor isolation, so the
/// constants are immutable `let`s and the builder is `nonisolated`;
/// ``RemoteTmuxControlConnection`` owns an instance and routes its seed call
/// sites through it. Defined once here so the alt-screen routing, the reconnect
/// re-seed, and the capture paint can't drift on the byte sequences they share.
public struct RemoteTmuxMirrorSeedSequences: Sendable {
    /// `ESC[?1049h` — enter the alternate screen, emitted to a mirror surface
    /// when the remote pane is on the alternate screen (see the `paneAltScreen`
    /// seed routing in ``RemoteTmuxControlConnection``).
    public let altScreenEnter = Data("\u{1b}[?1049h".utf8)

    /// `ESC[?1049l` — exit the alternate screen, forced on a mirror surface
    /// REUSED across reconnect when the remote pane is now on the primary screen
    /// so the capture doesn't paint onto a stale alt screen.
    public let altScreenExit = Data("\u{1b}[?1049l".utf8)

    /// `ESC[H ESC[2J ESC[3J` — home, clear the visible screen, and clear the
    /// scrollback. Emitted before re-seeding every pane on a reconnect so the
    /// re-seeded (possibly stale) frame starts from a clean surface.
    public let reconnectReseedClear = Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8)

    public init() {}

    /// Builds the capture-pane repaint output from the captured rows.
    ///
    /// Home + clear the VISIBLE SCREEN (`ESC[2J` — NOT `ESC[3J`, which would
    /// erase the scrollback being seeded), then join every captured row with
    /// CR LF: rows that overflow the screen scroll up into the surface's
    /// scrollback buffer, which is what makes the mirrored tab scrollable from
    /// the start. The last row (the visible bottom) gets no trailing newline so
    /// the cursor lands at its END, lining up with tmux's real prompt cursor.
    /// Returns `nil` only if the joined string is not valid UTF-8, matching the
    /// legacy `String.data(using:)` contract at the call site.
    public nonisolated func capturePaint(rows: [String]) -> Data? {
        let painted = "\u{1b}[H\u{1b}[2J" + rows.joined(separator: "\r\n")
        return painted.data(using: .utf8)
    }
}
