public import Foundation

/// A Ghostty theme file that cmux import generates from a source's colors.
public struct GhosttyThemeFile: Equatable, Sendable {
    /// Where the theme is written.
    public var url: URL
    /// The theme file body (`palette = 0=#...`, `background = #...` lines).
    public var contents: String

    /// Creates a theme file description.
    public init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }
}
