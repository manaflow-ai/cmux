import Testing
import WebKit
@testable import CmuxBrowser

/// The page agent is about 356 KB of script. Every attachment to a tab used
/// to add another copy that was never removed.
@MainActor
@Suite struct BrowserReplAgentUserScriptTests {
    private func install(_ installer: BrowserReplAgentUserScript, in controller: WKUserContentController) {
        installer.install(
            source: "globalThis.agentInstalls = (globalThis.agentInstalls || 0) + 1;",
            presenceHandlerName: "cmuxReplAgent",
            world: .world(name: "cmux-agent-test"),
            in: controller
        )
    }

    private func pageScript() -> WKUserScript {
        WKUserScript(source: "window.pageScript = 1;", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Each session attachment of a tab makes a new installer; the
    /// controller must still hold one agent.
    @Test func attachmentsToOneTabInstallTheAgentOnce() {
        let controller = WKUserContentController()
        install(BrowserReplAgentUserScript(), in: controller)
        install(BrowserReplAgentUserScript(), in: controller)
        install(BrowserReplAgentUserScript(), in: controller)
        #expect(controller.userScripts.count == 1)
    }

    @Test func releasingRemovesTheAgentAndKeepsOtherScripts() {
        let controller = WKUserContentController()
        let page = pageScript()
        controller.addUserScript(page)
        let installer = BrowserReplAgentUserScript()
        install(installer, in: controller)
        #expect(controller.userScripts.count == 2)
        installer.release()
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first === page)
    }

    /// A tab whose web view was replaced moves the agent to the new web
    /// view's controller.
    @Test func installingInANewControllerRemovesTheAgentFromTheOldOne() {
        let old = WKUserContentController()
        let new = WKUserContentController()
        let installer = BrowserReplAgentUserScript()
        install(installer, in: old)
        install(installer, in: new)
        #expect(old.userScripts.isEmpty)
        #expect(new.userScripts.count == 1)
    }

    @Test func aReleasedTabGetsTheAgentAgainOnTheNextAttachment() {
        let controller = WKUserContentController()
        let first = BrowserReplAgentUserScript()
        install(first, in: controller)
        first.release()
        install(BrowserReplAgentUserScript(), in: controller)
        #expect(controller.userScripts.count == 1)
    }
}
