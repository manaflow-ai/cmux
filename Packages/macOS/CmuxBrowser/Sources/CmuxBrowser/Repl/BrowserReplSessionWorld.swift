public import WebKit

/// The content world one REPL session's page agent lives in, in every tab
/// the session drives.
///
/// Every session that drives a tab shares one world named `cmux-agent`.
@MainActor
public final class BrowserReplSessionWorld {
    /// The world's name.
    public let name: String
    /// The session's agent world: the page agent, its refs and handles,
    /// and every `frame.evaluate` with `world: "agent"`.
    public let agent: WKContentWorld

    public init() {
        name = "cmux-agent"
        agent = .browserReplWorld(seeingClosedShadowRoots: name)
    }

    /// The world `frame.evaluate` runs `source` in for its `world`
    /// parameter: the session's agent world for `"agent"`, else the page's.
    public func evaluationWorld(_ world: String?) -> WKContentWorld {
        world == "agent" ? agent : .page
    }
}

/// How many sessions may drive one tab at once.
public struct BrowserReplTabSessionLimit: Sendable, Equatable {
    /// The most sessions attached to one tab at once.
    public let limit: Int

    public init(limit: Int) {
        self.limit = limit
    }

    /// The limit the app uses.
    public static let standard = BrowserReplTabSessionLimit(limit: .max)

    /// Throws when `sessionID` would be one session past the limit on a tab
    /// that `attached` sessions drive now. A session already attached
    /// passes.
    public func admit(_ sessionID: String, attached: some Collection<String>) throws {}
}
