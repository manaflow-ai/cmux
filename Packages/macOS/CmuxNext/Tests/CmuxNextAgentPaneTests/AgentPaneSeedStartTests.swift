import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat in Chromium made out of sight starts its page only when the page must run before anyone
/// sees it: a prompt that goes out by itself or an outside chat to adopt, which only the page sends
/// (and then `chat.persistSession`). The seeds are in memory only, so such a chat waiting for its
/// first show lost them when the app quit first. Any other chat (a restored tab with a kept draft,
/// a harness, a folder, no seed) makes no renderer until it shows (perf-lead.md F3).
@Suite(.serialized)
@MainActor
struct AgentPaneSeedStartTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func chat(_ seed: AgentPaneSeed?, _ hosting: FakeChromiumHosting) throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        let model = AgentPaneModel(host: NoHost(), seed: seed.map { AgentPaneSeedSource($0) })
        return try #require(AgentPaneView(model: model, source: .bundled(file), pageHost: true, chromium: hosting))
    }

    static let sendsBeforeShown: [AgentPaneSeed] = [
        AgentPaneSeed(prompt: "Fix the build", promptBy: .person),
        AgentPaneSeed(prompt: "First task", promptBy: .onboarding),
        AgentPaneSeed(adopt: AgentPaneAdopt(harness: "claude", agentSessionId: "outside-1")),
    ]

    @Test(arguments: sendsBeforeShown)
    func aChatThatMustSendStartsItsPageOutOfSight(seed: AgentPaneSeed) async throws {
        let hosting = FakeChromiumHosting()
        let view = try chat(seed, hosting)
        #expect(view.window == nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while hosting.made.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hosting.made.count == 1)
        #expect(view.page?.isWaitingForFirstShow == false)
        // Started, not shown.
        #expect(hosting.made.first?.visibility.contains(true) == false)
    }

    static let waitsForShow: [AgentPaneSeed?] = [
        nil,
        AgentPaneSeed(cwd: "/tmp"),
        AgentPaneSeed(draft: "kept text of a restored tab"),
        AgentPaneSeed(harness: "codex"),
        // A prompt from the CLI or a script waits in the composer anyway (no gesture ticket).
        AgentPaneSeed(prompt: "from a script", promptBy: .automation),
    ]

    @Test(arguments: waitsForShow)
    func aChatWithNothingToSendMakesNoPageUntilItShows(seed: AgentPaneSeed?) async throws {
        let hosting = FakeChromiumHosting()
        let view = try chat(seed, hosting)
        let page = try #require(view.page)
        #expect(page.isWaitingForFirstShow)
        #expect(hosting.made.isEmpty)
    }

    @Test func aSeedStillToBeReadIsADraftAndWaits() {
        let lazy = AgentPaneSeedSource { AgentPaneSeed(draft: "a page's selection") }
        #expect(!lazy.sendsBeforeShown)
        #expect(AgentPaneSeedSource(AgentPaneSeed(prompt: "go", promptBy: .person)).sendsBeforeShown)
    }
}
