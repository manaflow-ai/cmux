import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Cloud chat's sign-in page closes its tab once that sign-in ended (Leo: "this is simply logins,
/// done righr. end of story."), and only that tab (Leo: "WE ABSOLUELY MUST ERR ON THE SIDE OF BEING
/// NOT ANNOYING"): the card names the pages and hosts of an ended sign-in (`browser.signInEnded`), the
/// pane runs the closers the app gave for those pages' opens, each once, with only a sign-in's hosts.
@Suite
@MainActor
struct AgentPaneSignInTabsTests {
    static let claude = URL(string: "https://claude.ai/oauth/authorize?code=true")!
    static let codex = URL(string: "https://auth.openai.com/codex/device")!
    static let github = URL(string: "https://github.com/login/device")!

    final class Calls {
        var closed: [(String, [String])] = []
        func closer(_ name: String) -> AgentPaneSignInTabs.Closer {
            { [self] hosts in closed.append((name, hosts)) }
        }
    }

    @Test func anEndedSignInRunsItsOpensCloserOnceNewestFirst() {
        let calls = Calls()
        var tabs = AgentPaneSignInTabs()
        tabs.opened(Self.claude, close: calls.closer("claude"))
        tabs.opened(Self.codex, close: calls.closer("codex"))
        tabs.opened(Self.github, close: calls.closer("github"))
        for close in tabs.ended([Self.claude, Self.codex]) { close(["claude.ai"]) }
        #expect(calls.closed.map(\.0) == ["codex", "claude"])
        #expect(tabs.ended([Self.claude, Self.codex]).isEmpty, "each closes at most once")
        #expect(tabs.opens.map(\.url) == [Self.github])
        #expect(tabs.ended([URL(string: "https://claude.com/other")!]).isEmpty, "a page never opened closes nothing")
    }

    @Test func aSecondOpenOfThePageKeepsTheFirstCloser() {
        let calls = Calls()
        var tabs = AgentPaneSignInTabs()
        tabs.opened(Self.claude, close: calls.closer("first"))
        tabs.opened(Self.claude, close: calls.closer("second"))
        for close in tabs.ended([Self.claude]) { close([]) }
        #expect(calls.closed.map(\.0) == ["first"])
    }

    @Test func onlySignInPagesAreRecordedAndTheOldestGoPastTheLimit() {
        let calls = Calls()
        var tabs = AgentPaneSignInTabs()
        tabs.opened(URL(string: "https://example.com/login")!, close: calls.closer("other"))
        tabs.opened(URL(string: "https://github.com/settings/tokens")!, close: calls.closer("gh-other"))
        #expect(tabs.opens.isEmpty)
        let pages = (0...AgentPaneSignInTabs.limit).map { URL(string: "https://claude.ai/oauth/authorize?n=\($0)")! }
        for (n, page) in pages.enumerated() { tabs.opened(page, close: calls.closer("\(n)")) }
        #expect(tabs.opens.count == AgentPaneSignInTabs.limit)
        #expect(tabs.opens.first?.url == pages[1], "the oldest open is dropped")
    }

    @Test func onlyASignInsOwnHostsReachTheCloser() {
        #expect(AgentPaneSignInTabs.ownHosts(["Claude.AI", "auth.openai.com", "github.com", "example.com", "mail.google.com"])
            == ["claude.ai", "auth.openai.com", "github.com"])
        #expect(AgentPaneSignInTabs.ownHosts([]).isEmpty)
    }

    @Test func theCardsSignInEndedParsesStrictlyAndIsPassive() throws {
        let request = try #require(AgentPaneReplyRequest(method: "browser.signInEnded", params: [
            "urls": [Self.claude.absoluteString, Self.github.absoluteString], "hosts": ["claude.ai"],
        ]))
        guard case .signInEnded(let urls, let hosts) = request else { Issue.record("\(request)"); return }
        #expect(urls == [Self.claude, Self.github])
        #expect(hosts == ["claude.ai"])
        #expect(request.isPassive, "closing a sign-in's own tab needs no click")

        // `hosts` may be left out (an acpmux that names none).
        let bare = try #require(AgentPaneReplyRequest(method: "browser.signInEnded", params: ["urls": [Self.codex.absoluteString]]))
        guard case .signInEnded(_, let none) = bare else { Issue.record("\(bare)"); return }
        #expect(none.isEmpty)

        for params: [String: Any] in [
            [:],
            ["urls": ["https://example.com/login"]],
            ["urls": [Self.claude.absoluteString, "https://example.com/"]],
            ["urls": [Self.claude.absoluteString], "tab": "t1"],
            ["urls": (0..<9).map { "https://claude.ai/oauth/authorize?n=\($0)" }],
            ["urls": [Self.claude.absoluteString], "hosts": (0..<17).map { "h\($0).claude.ai" }],
        ] {
            #expect(AgentPaneReplyRequest(method: "browser.signInEnded", params: params) == nil, "\(params)")
        }
    }
}
