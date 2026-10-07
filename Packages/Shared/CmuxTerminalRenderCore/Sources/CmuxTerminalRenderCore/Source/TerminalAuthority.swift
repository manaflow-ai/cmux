/// Who owns the terminal's parser state and grid.
public enum TerminalAuthority: Hashable, Sendable {
    /// A session host owns the PTY, the parser that answers queries, the
    /// scrollback and the grid (cmux-tui on a Mac, mini or Cloud VM). The
    /// renderer mirrors it: it parses only to draw, drops parser replies,
    /// takes its grid from `TerminalSourceEvent.grid` and repairs drift from
    /// GHOSTSNP snapshots (`terminal-snapshot-v1`).
    case host
    /// The renderer is the only parser (an SSH channel, a fixture replay).
    /// It answers terminal queries through `TerminalByteSource.send`, its
    /// grid follows the view, and every viewport change is reported (the SSH
    /// window-change).
    case local
}
