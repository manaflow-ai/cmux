public import WebKit

/// The content world one REPL session's page agent lives in, in every tab
/// the session drives.
///
/// Each session gets a world of its own, so code one session runs in its
/// agent world (`frame.evaluate` with `world: "agent"`) shares nothing with
/// another session's agent: patched built-ins, DOM prototypes,
/// `window.frames` or the agent object stay in the world that patched them,
/// and another session's refs, handles, hit tests and press checks read
/// their own. The driver's guards run in worlds of their own that no
/// session's `source` reaches (``evaluationWorld(_:)``).
///
/// A world's name is used once (`cmux-agent-<random>`): WebKit gives a
/// named world back by name while anything still holds it, and has no call
/// that clears what a world holds in a loaded document, so a name is never
/// handed to a later session, which then never sees what an ended session
/// left in a page. The world is configured to see closed shadow roots
/// (``WebKit/WKContentWorld/browserReplWorld(seeingClosedShadowRoots:)``).
@MainActor
public final class BrowserReplSessionWorld {
    /// Every agent world's name starts with this.
    public static let namePrefix = "cmux-agent-"

    /// The world's name, never used for another session.
    public let name: String
    /// The session's agent world: the page agent, its refs and handles,
    /// and every `frame.evaluate` with `world: "agent"`.
    public let agent: WKContentWorld

    public init() {
        name = Self.namePrefix + UUID().uuidString.lowercased()
        agent = .browserReplWorld(seeingClosedShadowRoots: name)
    }

    /// The world `frame.evaluate` runs `source` in for its `world`
    /// parameter: the session's agent world for `"agent"`, else the page's.
    /// No value names a guard world or another session's world.
    public func evaluationWorld(_ world: String?) -> WKContentWorld {
        world == "agent" ? agent : .page
    }
}

/// How many sessions may drive one tab at once.
///
/// Each session that drives a tab runs its own page agent (about 400 KB of
/// script) in every frame of every document the tab loads, so the cost of
/// a navigation grows with the sessions on the tab
/// (docs/browser-repl/performance.md, Agent worlds).
public struct BrowserReplTabSessionLimit: Sendable, Equatable {
    /// The most sessions attached to one tab at once.
    public let limit: Int

    public init(limit: Int) {
        self.limit = limit
    }

    /// The limit the app uses.
    public static let standard = BrowserReplTabSessionLimit(limit: 4)

    /// Throws `limit` when `sessionID` would be one session past the limit
    /// on a tab that `attached` sessions drive now. A session already
    /// attached passes.
    public func admit(_ sessionID: String, attached: some Collection<String>) throws {
        guard !attached.contains(sessionID), attached.count >= limit else { return }
        throw BrowserReplDriverError(
            code: "limit",
            message: "REPL session limit: sessions driving one tab at most \(limit) at once (\(attached.count) held, this needs 1 more); end a session that drives this tab, or open another tab with tabs.open"
        )
    }
}
