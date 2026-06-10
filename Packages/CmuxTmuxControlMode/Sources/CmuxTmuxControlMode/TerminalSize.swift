import Foundation

/// A terminal grid size in character cells. Used to drive `refresh-client -C`.
public struct TerminalSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        // tmux refuses sizes below 1x1; clamp so we never emit a malformed
        // refresh-client command.
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}
