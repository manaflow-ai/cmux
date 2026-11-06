import Testing
@testable import CmuxNextAgentPane

/// The New Tab page's Open in Profile… and Open in New Profile rows (Lawrence 2026-11-05: "open it in
/// certain profile … as well as open url in a completely new profile") reach the host as `tab.open`
/// with the profile the row named.
@Suite
struct AgentPaneOpenInProfileRequestTests {
    private func open(_ params: [String: Any]) -> AgentPaneOpenTab? {
        guard case .openTab(let request) = AgentPaneRequest(body: ["method": "tab.open", "params": params]) else { return nil }
        return request
    }

    @Test func aProfileRowOpensTheAddressInThatProfile() throws {
        let request = try #require(open(["kind": "browser", "text": "https://example.com", "profile": "p-work"]))
        #expect(request.kind == .browser)
        #expect(request.text == "https://example.com")
        #expect(request.profile == .existing("p-work"))
    }

    @Test func theNewProfileRowsAskForAProfileNamedAfterTheSearchOrTheDefaultName() throws {
        let named = try #require(open(["kind": "browser", "text": "https://example.com", "newProfile": true, "profileName": "  Client X "]))
        #expect(named.profile == .new(name: "Client X"))
        let unnamed = try #require(open(["kind": "browser", "text": "https://example.com", "newProfile": true, "profileName": "   "]))
        #expect(unnamed.profile == .new(name: nil))
    }

    @Test func aPlainOpenOrATerminalNamesNoProfile() throws {
        #expect(try #require(open(["kind": "browser", "text": "https://example.com"])).profile == nil)
        // A terminal has no browser profile, whatever the page sent.
        #expect(try #require(open(["kind": "terminal", "text": "ls", "profile": "p-work"])).profile == nil)
        // An id no profile could have (empty, too long) opens in the usual profile.
        #expect(try #require(open(["kind": "browser", "text": "https://example.com", "profile": ""])).profile == nil)
        let long = String(repeating: "x", count: 300)
        #expect(try #require(open(["kind": "browser", "text": "https://example.com", "profile": long])).profile == nil)
    }
}
