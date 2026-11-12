/// The effective Ghostty terminal options plus, per key, the config file that
/// made the last assignment, so Settings can name the file that overrides a
/// value it just wrote.
public struct GhosttyTerminalOptionsSnapshot: Equatable, Sendable {
    /// The effective values.
    public var options: GhosttyTerminalOptions
    /// Display path (for example `~/.config/ghostty/extra`) of the file that
    /// last assigned each key. Keys no file sets are absent.
    public var sourcePaths: [GhosttyTerminalOptionKey: String]

    public init(
        options: GhosttyTerminalOptions,
        sourcePaths: [GhosttyTerminalOptionKey: String] = [:]
    ) {
        self.options = options
        self.sourcePaths = sourcePaths
    }

    /// Ghostty's defaults with no source files.
    public static let defaults = GhosttyTerminalOptionsSnapshot(options: .defaults)
}
