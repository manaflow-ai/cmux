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
}
