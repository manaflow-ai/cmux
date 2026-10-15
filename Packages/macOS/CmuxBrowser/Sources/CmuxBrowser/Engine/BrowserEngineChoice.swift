import Foundation

/// The engine a new browser panel gets, and why.
public struct BrowserEngineChoice: Equatable, Hashable, Sendable {
    /// The engine the panel opens with.
    public var engine: BrowserEngineKind
    /// Set when Chromium was wanted but unavailable and the panel opens in
    /// WebKit instead. The panel shows a visible notice with this reason.
    public var fallback: BrowserEngineUnavailableReason?
    /// Where the choice came from.
    public var source: BrowserEngineChoiceSource

    /// Creates a choice.
    /// - Parameters:
    ///   - engine: The engine the panel opens with.
    ///   - fallback: The reason the wanted engine was replaced, or `nil`.
    ///   - source: Where the choice came from.
    public init(
        engine: BrowserEngineKind,
        fallback: BrowserEngineUnavailableReason? = nil,
        source: BrowserEngineChoiceSource
    ) {
        self.engine = engine
        self.fallback = fallback
        self.source = source
    }
}
