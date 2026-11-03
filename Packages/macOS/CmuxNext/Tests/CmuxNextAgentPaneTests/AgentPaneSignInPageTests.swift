import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Cloud chat's Sign in is one click (Leo 2026-11-02: one "Sign in to Claude" button): the click's
/// gesture goes to `_acpmux/agent_login/start`, and that start leaves one open of the provider's
/// sign-in page, so the card opens it with no second click. Only a start that took the person's
/// gesture leaves it, only a provider sign-in page spends it, and only once.
@Suite(.serialized)
@MainActor
struct AgentPaneSignInPageTests {
    static let page = URL(string: "https://claude.com/cai/oauth/authorize?code=true&state=s")!

    /// A pane with its chat (the stand-in's `s-new`), started with no gesture of the person's.
    static func pane() async throws -> AgentPaneSlowStartPromptTests.Pane {
        let pane = try await AgentPaneSlowStartPromptTests.pane()
        #expect(await AgentPaneSlowStartPromptTests.start(pane, id: 100) == nil)
        return pane
    }

    static func start(_ pane: AgentPaneSlowStartPromptTests.Pane, id: Int) async -> AgentPaneTransportError? {
        let frame = #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/agent_login/start","params":{"agent":"claude","sessionId":"s-new"}}"#
        return await pane.transport.send(connection: pane.id, frames: [frame])
    }

    @Test func theSignInClickAlsoOpensItsPageOnce() async throws {
        let pane = try await Self.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record(click: true)
        #expect(await Self.start(pane, id: 1) == nil)
        #expect(!pane.transport.gestures.isAvailable, "the start took the click's gesture")
        // Any page but a provider's sign-in page is not opened on it, and leaves the credit.
        #expect(!pane.transport.takeSignInPage(URL(string: "https://evil.example/login")!))
        #expect(!pane.transport.takeSignInPage(URL(string: "http://claude.ai/oauth/authorize")!))
        #expect(!pane.transport.takeSignInPage(URL(string: "https://claude.ai:8443/oauth/authorize")!))
        pane.clock.now += 25
        #expect(pane.transport.takeSignInPage(Self.page), "the Sign in click opens its page")
        #expect(!pane.transport.takeSignInPage(Self.page), "once")
    }

    @Test func aStartWithoutTheClickOpensNothing() async throws {
        let pane = try await Self.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        // A start the page made by itself is refused and leaves nothing.
        #expect(await Self.start(pane, id: 1) == .gestureRequired)
        #expect(!pane.transport.takeSignInPage(Self.page))

        // A start under the gesture whose page comes after the credit's lifetime opens nothing.
        pane.transport.gestures.record(click: true)
        #expect(await Self.start(pane, id: 2) == nil)
        pane.clock.now += AgentPaneSignInPage.lifetime + 1
        #expect(!pane.transport.takeSignInPage(Self.page))
    }

    @Test func onlyProviderSignInPagesAreAllowed() {
        #expect(AgentPaneSignInPage.allowed(Self.page))
        #expect(AgentPaneSignInPage.allowed(URL(string: "https://auth.openai.com/codex/device")!))
        #expect(!AgentPaneSignInPage.allowed(URL(string: "https://claude.ai.evil.example/oauth")!))
        #expect(!AgentPaneSignInPage.allowed(URL(string: "https://user:pass@claude.ai/oauth")!))
        #expect(!AgentPaneSignInPage.allowed(URL(string: "javascript:alert(1)")!))
    }

    static let automatic = URL(string: "https://claude.com/cai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=s")!

    /// Claude's automatic page: an allowed page whose one redirect is its own listener's
    /// `http://localhost:<port>/callback` on the chat's machine (Leo 2026-11-02: no code to paste).
    @Test func onlyClaudesAutomaticPageNamesALocalhostCallback() {
        #expect(AgentPaneSignInPage.callbackPort(Self.automatic) == 54545)
        #expect(AgentPaneSignInPage.callbackPort(Self.page) == nil)
        let redirect = { (target: String) -> URL in
            var parts = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
            parts.queryItems = [URLQueryItem(name: "redirect_uri", value: target)]
            return parts.url!
        }
        #expect(AgentPaneSignInPage.callbackPort(redirect("http://localhost:49152/callback")) == 49152)
        for bad in ["https://platform.claude.com/oauth/code/callback", "http://evil.example:54545/callback",
                    "http://localhost.evil.example:54545/callback", "http://127.0.0.1:54545/callback",
                    "https://localhost:54545/callback", "http://localhost:54545/other", "http://localhost/callback",
                    "http://localhost:0/callback", "http://localhost:070/callback", "http://localhost:+80/callback",
                    "http://localhost:99999/callback"] {
            #expect(AgentPaneSignInPage.callbackPort(redirect(bad)) == nil, "\(bad)")
        }
        let two = URL(string: "https://claude.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback&redirect_uri=http%3A%2F%2Flocalhost%3A2%2Fcallback")!
        #expect(AgentPaneSignInPage.callbackPort(two) == nil)
        let elsewhere = URL(string: "https://evil.example/oauth?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback")!
        #expect(AgentPaneSignInPage.callbackPort(elsewhere) == nil)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Opens { var count = 0 }

    /// The page asks for the automatic page on the chat's machine (`browser.openIn` with
    /// `cmux-chat-machine`): the host opens it only when it can make that tab, only for that page,
    /// and only on the person's click; a host that cannot keeps the click for the code page.
    @Test func theAutomaticPageOpensOnTheChatsMachineOnlyWhenTheHostCan() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat")
        let request = AgentPaneReplyRequest.openIn(url: Self.automatic, browserId: AgentPaneSignInPage.chatMachineBrowser)
        model.transport.gestures.record(click: true)
        #expect(await model.respond(to: request)["ok"] as? Bool == false, "no host open")
        #expect(model.transport.gestures.isAvailable, "the click stays for the code page")

        let opens = Opens()
        let open: @MainActor () -> Bool = {
            opens.count += 1
            return true
        }
        model.onOpenSignInOnMachine = { (url: URL) -> (@MainActor () -> Bool)? in
            url == Self.automatic ? open : nil
        }
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        #expect(opens.count == 1)
        #expect(await model.respond(to: request)["ok"] as? Bool == false, "no click, no open")
        #expect(opens.count == 1)

        model.transport.gestures.record(click: true)
        let codePage = AgentPaneReplyRequest.openIn(url: Self.page, browserId: AgentPaneSignInPage.chatMachineBrowser)
        #expect(await model.respond(to: codePage)["ok"] as? Bool == false, "only the automatic page")
        #expect(opens.count == 1)
    }
}
