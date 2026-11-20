import CmuxNextActions
import Foundation
import Testing

/// A public PR footer's opaque agent link (`https://cmux.com/deeplink/agent?id=aid-…`), and the
/// `cmux://agent?id=aid-…` cmux.com's page hands the app on load, read as the reference acpmux
/// resolves to the chat, so a click lands in the app (Leo, 2026-11-11: "if i click on it cant it
/// autodirect instead of going to website auto? like discord").
struct DeepLinkAgentReferenceTests {
    private let id = "aid-d750cf10922c785efa64"

    private func reference(_ text: String) -> String? {
        DeepLink.agentReference(URL(string: text)!, linkScheme: "cmux-dev-tag")
    }

    @Test(arguments: [
        "cmux://agent?id=aid-d750cf10922c785efa64",
        "cmux://agent/?id=aid-d750cf10922c785efa64",
        "cmux-dev-tag://agent?id=aid-d750cf10922c785efa64",
        "https://cmux.com/deeplink/agent?id=aid-d750cf10922c785efa64",
        "https://www.cmux.com/en/deeplink/agent/?id=aid-d750cf10922c785efa64",
    ])
    func aFooterLinkAndWhatThePageOpensNameTheReference(_ text: String) {
        #expect(reference(text) == id)
    }

    @Test(arguments: [
        "cmux://agent?id=aid-D750CF10922C785EFA64",
        "cmux://agent?id=aid-d750cf10922c785efa6",
        "cmux://agent?id=aid-d750cf10922c785efa64%0A",
        "cmux://agent?id=aid-d750cf10922c785efa64&id=aid-d750cf10922c785efa64",
        "cmux://agent?id=aid-d750cf10922c785efa64&session=s1",
        "cmux://agent?id=aid-d750cf10922c785efa64&harness=claude",
        "cmux://agent/claude/s1?id=aid-d750cf10922c785efa64",
        "cmux://agent?id=aid-d750cf10922c785efa64#x",
        "cmux://session?id=aid-d750cf10922c785efa64",
        "other://agent?id=aid-d750cf10922c785efa64",
        "https://evil.com/deeplink/agent?id=aid-d750cf10922c785efa64",
        "https://cmux.com/deeplink/agent?harness=claude&session=s1",
        "cmux://agent",
    ])
    func anythingElseNamesNone(_ text: String) {
        #expect(reference(text) == nil)
    }

    /// A harness link still reads as the agent link it is, not as a reference.
    @Test func aHarnessLinkIsNoReference() {
        #expect(DeepLink.parseAgentWeb(URL(string: "https://cmux.com/deeplink/agent?id=\(id)")!) == nil)
        #expect(DeepLink.isAgentReference(id))
        #expect(!DeepLink.isAgentReference(id + "\n"))
    }
}
