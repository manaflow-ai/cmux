public import WebKit

/// A frame's document as the domain policy judges it.
public struct BrowserReplFrameDocument: Sendable, Equatable {
    public var origin: String?
    public var place: String

    public init(origin: String?, place: String) {
        self.origin = origin
        self.place = place
    }
}

/// Applies a REPL session's domain policy to every frame of a tab.
///
/// Inert in this commit: `authorize` refuses nothing.
@MainActor
public final class BrowserReplFrameGate {
    /// The session's policy; only the native session sets it.
    public var policy = BrowserReplDomainPolicy()
    private let world: WKContentWorld

    /// - Parameter world: a content world agent and page code cannot reach.
    public init(world: WKContentWorld) {
        self.world = world
    }

    /// Reads the document `frame` shows now and throws `blocked` when the
    /// policy blocks it.
    @discardableResult
    public func authorize(_ frame: BrowserReplFrame, in webView: WKWebView) async throws -> BrowserReplFrameDocument? {
        nil
    }
}
