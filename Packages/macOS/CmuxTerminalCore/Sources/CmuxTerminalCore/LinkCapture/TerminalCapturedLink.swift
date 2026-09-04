/// A URL emitted by terminal output before terminal layout wrapping is applied.
public struct TerminalCapturedLink: Equatable, Sendable {
    /// Compatibility name for the capture-path vocabulary.
    public typealias Source = TerminalCapturedLinkSource

    /// The full URL string observed in the output stream.
    public var url: String
    /// The capture path that found the URL.
    public var source: Source

    /// Creates a captured terminal link.
    ///
    /// - Parameters:
    ///   - url: The full URL string observed in terminal output.
    ///   - source: The capture path that found the URL.
    public init(url: String, source: Source) {
        self.url = url
        self.source = source
    }
}
