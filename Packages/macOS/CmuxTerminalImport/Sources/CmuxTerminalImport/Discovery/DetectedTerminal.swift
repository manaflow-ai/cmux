public import Foundation

/// A terminal found on this Mac with settings `cmux import` can read.
public struct DetectedTerminal: Equatable, Sendable {
    /// Which terminal.
    public var source: TerminalImportSource
    /// The config file, for file-based sources; `nil` for preferences-based ones.
    public var configURL: URL?
    /// A short description such as `profile "Default"` or a list of Warp themes.
    public var detail: String

    /// Creates a detection result.
    public init(source: TerminalImportSource, configURL: URL?, detail: String) {
        self.source = source
        self.configURL = configURL
        self.detail = detail
    }
}
