public import Foundation
import Synchronization
import os

/// A VT snapshot that reproduces the terminal when fed to a fresh mirror of
/// `cols` x `rows`.
public struct TerminalReplay: Sendable, Hashable {
    public var cols: Int
    public var rows: Int
    public var data: Data
    public var colors: TerminalColors?
    public var kittyImageAliases: [KittyImageAlias]
    public var kittyGraphicsState: KittyGraphicsState?
    /// The unfinished escape sequence (or UTF-8 code point) the daemon's
    /// parser was inside when it took the replay
    /// (`terminal-pending-sequence-v1`). Write it after `data`, the Kitty
    /// state and any sequences of your own, right before live output, which
    /// completes it. Empty at a parser boundary.
    public var pending: Data

    public init(cols: Int, rows: Int, data: Data, colors: TerminalColors? = nil,
                kittyImageAliases: [KittyImageAlias] = [], kittyGraphicsState: KittyGraphicsState? = nil,
                pending: Data = Data()) {
        self.cols = cols
        self.rows = rows
        self.data = data
        self.colors = colors
        self.kittyImageAliases = kittyImageAliases
        self.kittyGraphicsState = kittyGraphicsState
        self.pending = pending
    }
}
