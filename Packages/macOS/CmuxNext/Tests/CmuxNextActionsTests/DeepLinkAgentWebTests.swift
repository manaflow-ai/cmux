import CmuxNextActions
import Foundation
import Testing

/// The https agent session link (`https://cmux.com/deeplink/agent?harness=&session=`, every PR
/// footer's and agent reply's) reads as its `cmux://agent/<harness>/<session>` form, so a click on
/// it in the app opens the chat here instead of its web page (Leo, 2026-11-03: "we need to be able
/// to link WITHIN THE APP").
struct DeepLinkAgentWebTests {
    private func web(_ text: String) -> DeepLink? {
        DeepLink.parseAgentWeb(URL(string: text)!)
    }

    @Test func aFooterLinkIsTheAgentLinkItNames() throws {
        let link = try #require(web(
            "https://cmux.com/deeplink/agent?harness=claude&session=01a18a35-b23b-7b61-9798-dba14474a974&host=cosmic-gray"))
        #expect(link.target == .agent(harness: "claude", session: "01a18a35-b23b-7b61-9798-dba14474a974"))
        #expect(link.hostHint == "cosmic-gray")
        #expect(link.url(scheme: "cmux")?.absoluteString
            == "cmux://agent/claude/01a18a35-b23b-7b61-9798-dba14474a974?host=cosmic-gray")
    }

    @Test(arguments: [
        "https://www.cmux.com/deeplink/agent/?harness=codex&session=s:1",
        "https://cmux.com/en/deeplink/agent?harness=codex&session=s:1",
        "https://cmux.com/zh-CN/deeplink/agent?harness=codex&session=s:1&name=lane",
    ])
    func everyFormOfThePageReads(_ text: String) throws {
        let link = try #require(web(text))
        #expect(link.target == .agent(harness: "codex", session: "s:1"))
    }

    @Test func aMessageRidesAlong() throws {
        let link = try #require(web("https://cmux.com/deeplink/agent?harness=claude&session=s1&message=m_1"))
        #expect(link.message == "m_1")
    }

    /// Leo's screenshot: a lane's `?session=&host=` link with no harness opened the web page on
    /// "missing required parameters: harness". It names a harness session id acpmux resolves.
    @Test func aLinkWithNoHarnessNamesItsSessionID() throws {
        let url = URL(string: "https://cmux.com/deeplink/agent?session=01a19f86-e54b-78b3-9911-4326190bc1aa&host=cosmic-gray")!
        #expect(DeepLink.parseAgentWeb(url) == nil)
        #expect(DeepLink.agentWebSession(url) == "01a19f86-e54b-78b3-9911-4326190bc1aa")
        #expect(DeepLink.agentWebSession(URL(string: "https://cmux.com/deeplink/agent?harness=claude&session=s1")!) == nil)
        #expect(DeepLink.agentWebSession(URL(string: "https://cmux.com/deeplink/agent?session=a&session=b")!) == nil)
        #expect(DeepLink.agentWebSession(URL(string: "https://evil.com/deeplink/agent?session=s1")!) == nil)
        #expect(DeepLink.agentWebSession(URL(string: "https://cmux.com/deeplink/agent?id=aid-81baa1463f6190d4c5dc")!) == nil)
    }

    @Test(arguments: [
        // The opaque form names no session.
        "https://cmux.com/deeplink/agent?id=aid-81baa1463f6190d4c5dc",
        "https://cmux.com/deeplink/agent?harness=claude",
        "https://cmux.com/deeplink/agent?harness=claude&session=a&session=b",
        "https://cmux.com/deeplink/agent?harness=Not%20one&session=s1",
        "http://cmux.com/deeplink/agent?harness=claude&session=s1",
        "https://evil.com/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com.evil.com/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com:8443/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com/x/y/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com/deeplink/agentx?harness=claude&session=s1",
        "https://cmux.com/deeplink/agent?harness=claude&session=s1#frag",
        "cmux://agent/claude/s1",
    ])
    func anythingElseIsNotOne(_ text: String) {
        #expect(web(text) == nil)
    }
}
