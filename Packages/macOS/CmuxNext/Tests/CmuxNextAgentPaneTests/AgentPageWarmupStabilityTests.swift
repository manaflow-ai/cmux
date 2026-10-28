import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSignposts
import CmuxNextTrace
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The agent pages' WebKit warm-up page hears its content process's end whenever it was made,
/// before the launch settled too, and that end is one `warmup` stability event; the page stays until the settle.
@MainActor @Suite struct AgentPageWarmupStabilityTests {
    private final class Reports {
        var surfaces: [RendererStability.Surface] = []
    }

    @Test func theWarmupPagesContentEndIsAWarmupEvent() throws {
        let reports = Reports()
        let stability = RendererStability(trace: TraceRuntime(role: .app)) { reports.surfaces.append($0.surface) }
        let warmup = AgentPageWarmup(chromiumChat: { false }, stability: stability)
        #expect(warmup.start(webUI: .agentPaneTestHost(chromium: FakeChromiumHosting())) == .made)
        let page = try #require(warmup.page)
        let delegate = try #require(page.navigationDelegate, "a page made before the settle hears its process too")

        delegate.webViewWebContentProcessDidTerminate?(page)

        #expect(reports.surfaces == [.warmup])
        #expect(warmup.page === page, "before the launch settled the page stays until the settle")
        warmup.settle()
        #expect(warmup.page == nil)
    }

    @Test func aWarmupWithoutStabilityStillGoesAtItsLoadEndAfterTheSettle() throws {
        let warmup = AgentPageWarmup(chromiumChat: { false })
        warmup.settle()
        #expect(warmup.start(webUI: .agentPaneTestHost(chromium: FakeChromiumHosting())) == .made)
        let page = try #require(warmup.page)
        try #require(page.navigationDelegate).webViewWebContentProcessDidTerminate?(page)
        #expect(warmup.page == nil, "a page made after the settle goes when its process ends")
    }
}
