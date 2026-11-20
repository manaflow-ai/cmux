import AppKit
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A New Tab tab can take a page view whose page did not ask for its handshake yet: a New Tab key takes the
/// untouched page view of the tab that its pane leaves, and in a hold that page view can be a few frames old.
///
/// The tab tells the page its own context with an event (`AgentPaneView.adoptNewTab`). By a read of the page's
/// source, a page hears that event only after its first render, and it adds that listener before it asks for
/// its handshake (`ready`). An event that comes before is lost. A page that drew from the context that came
/// with its document takes only a missing folder and missing actions from the handshake's reply, so such a page
/// keeps the context of the tab that had the page view before: another tab's token for typed keys, folder and
/// open tabs.
///
/// The row: a page view with no handshake, then 1 or 2 takes (`AgentPaneView.adoptNewTab`, the call of each take
/// of the tab store), then the page's `ready` as the page's message handler answers it
/// (`AgentPaneBridge.reply(to:)`). Want: after the host made its reply, the host sent the adopt event ONE more
/// time, with the context of the tab that has the page view (the last take). Then, what must stay: a second
/// `ready` of the same page view gets no adopt event, a take after the handshake sends its ONE event at the take,
/// and a `ready` after that take gets none.
///
/// Limits. The page view is a WebKit one with no document: the row reads the scripts that the host sends
/// (`AgentPaneView.evaluateScript`) and the host's reply, and no page runs. That a page listens at its handshake
/// is by a read of the page's source, not by this row. The host is a stand-in that answers each handshake at once.
@MainActor @Suite
struct NewTabAdoptBeforeHandshakeTests {
    struct Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    }

    /// The adopt events that the host sent to the page view, each with the host's handshake mark at its send.
    @MainActor final class Sent {
        struct Adopt {
            let script: String
            let afterHandshake: Bool
        }

        private(set) var adopts: [Adopt] = []

        func note(_ script: String, handshake: Bool) {
            guard script.contains("acpmux-newtab-adopt") else { return }
            adopts.append(Adopt(script: script, afterHandshake: handshake))
        }
    }

    /// The token for typed keys of the tab number `tab`: it is in that tab's context only.
    static func token(_ tab: Int) -> String { "input-token-of-tab-\(tab)" }

    /// The context of the tab number `tab`.
    static func context(tab: Int) -> AgentPaneNewTab {
        var page = AgentPaneNewTab(kind: .agent)
        page.inputToken = token(tab)
        return page
    }

    /// The token in the `newTab` object of a reply to `ready`.
    static func token(of reply: [String: Any]) -> String? {
        let value = reply["value"] as? [String: Any]
        return (value?["newTab"] as? [String: Any])?["inputToken"] as? String
    }

    @Test(arguments: [1, 2])
    func aPageViewThatATabTookBeforeItsHandshakeGetsThatTabsContextAgainAfterIt(takes: Int) async throws {
        _ = NSApplication.shared
        let model = AgentPaneModel(host: Host(), newTab: Self.context(tab: 0))
        model.startFolders.resolve = { _ in nil }
        let source = AgentPaneSource.bundled(URL(filePath: "/dev/null"))
        let view = try #require(AgentPaneView(model: model, source: source), "setup: no page view")
        let sent = Sent()
        view.evaluateScript = { script in sent.note(script, handshake: model.hasHandshake) }

        for tab in 1...takes { view.adoptNewTab(Self.context(tab: tab)) }
        try #require(!model.hasHandshake, "setup: the page view has its handshake before a page asked for one")
        try #require(sent.adopts.count == takes, "setup: \(sent.adopts.count) adopt events at \(takes) take(s)")
        let last = Self.token(takes)
        try #require(sent.adopts.last?.script.contains(last) == true, "setup: the take's event has no token of its tab")

        let bridge = AgentPaneBridge(view: view)
        let reply = await bridge.reply(to: .ready)
        try #require(model.hasHandshake, "setup: the host's reply to `ready` set no handshake mark")
        let again = Array(sent.adopts.dropFirst(takes))
        let withTheTabs = again.filter { $0.script.contains(last) }.count
        let afterTheReply = again.filter(\.afterHandshake).count

        let atFirstReady = sent.adopts.count
        _ = await bridge.reply(to: .ready)
        let atSecondReady = sent.adopts.count - atFirstReady

        view.adoptNewTab(Self.context(tab: takes + 1))
        let atLateTake = sent.adopts.count - atFirstReady - atSecondReady
        _ = await bridge.reply(to: .ready)
        let atThirdReady = sent.adopts.count - atFirstReady - atSecondReady - atLateTake

        print("""
            NewTabAdoptBeforeHandshakeTests: \(takes) take(s) of a page view before its handshake: adopt events that \
            the host sent in its answer to the page's first `ready`: \(again.count) (with the context of the tab that \
            has the page view: \(withTheTabs), after the host made its reply: \(afterTheReply)); the reply has that \
            tab's context: \(Self.token(of: reply) == last); adopt events at a second `ready`: \(atSecondReady); at a \
            take after the handshake: \(atLateTake); at a `ready` after that take: \(atThirdReady)
            """)
        #expect(again.count == 1,
                "the host sent \(again.count) adopt events after the handshake of a page view that a tab took before it")
        #expect(withTheTabs == again.count, "an adopt event after the handshake has another tab's context")
        #expect(afterTheReply == again.count, "an adopt event of the answer to `ready` went out before the host's reply")
        #expect(Self.token(of: reply) == last, "the host's reply to `ready` has another tab's context")
        #expect(atSecondReady == 0, "a second `ready` of the same page view got \(atSecondReady) adopt event(s)")
        #expect(atLateTake == 1, "a take after the handshake sent \(atLateTake) adopt events")
        #expect(atThirdReady == 0, "a `ready` after a take that came after the handshake got \(atThirdReady) adopt event(s)")
    }
}
