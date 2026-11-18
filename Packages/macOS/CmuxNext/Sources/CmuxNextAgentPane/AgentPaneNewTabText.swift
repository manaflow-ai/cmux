public import Foundation

/// Makes the JSON of a New Tab page's context for a page. The context is large (the bar's lists), so each
/// make is main thread time in a New Tab key's frames: `encodes` counts the makes, for the tests that hold
/// how many pages cost one.
@MainActor public final class AgentPaneNewTabText {
    public private(set) var encodes = 0
    public init() {}
    public func data(of page: AgentPaneNewTab) throws -> Data { encodes += 1; return try JSONEncoder().encode(page) }
}
