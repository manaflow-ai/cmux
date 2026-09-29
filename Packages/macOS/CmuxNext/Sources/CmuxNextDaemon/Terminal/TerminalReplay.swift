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

    public init(cols: Int, rows: Int, data: Data, colors: TerminalColors? = nil,
                kittyImageAliases: [KittyImageAlias] = [], kittyGraphicsState: KittyGraphicsState? = nil) {
        self.cols = cols
        self.rows = rows
        self.data = data
        self.colors = colors
        self.kittyImageAliases = kittyImageAliases
        self.kittyGraphicsState = kittyGraphicsState
    }
}
