import CmuxNextBrowser
import CmuxNextBrowserAutomation
@testable import CmuxNextBrowserHost
import Testing

/// cmux https://github.com/manaflow-ai/cmux/issues/25830: the browser host's agent code passes the
/// Secure Store login guard (`ProviderScriptGate`): every `frame.evaluate` outside the host's own
/// world and every cookie write; reads, input and the host world do not.
@Suite struct ProviderScriptGateTests {
    @Test func agentCodeIsEvaluateOutsideTheHostWorldAndCookieWrites() {
        let page: DriverJSON = .object(["targetId": .string("tab_1"), "world": .string("page")])
        let agent: DriverJSON = .object(["targetId": .string("tab_1"), "world": .string("agent")])
        let unnamed: DriverJSON = .object(["targetId": .string("tab_1")])
        let host: DriverJSON = .object(["targetId": .string("tab_1"), "world": .string("host")])
        #expect(BrowserHostProvider.runsAgentCode("frame.evaluate", page))
        #expect(BrowserHostProvider.runsAgentCode("frame.evaluate", agent))
        #expect(BrowserHostProvider.runsAgentCode("frame.evaluate", unnamed), "the page world is the default")
        #expect(!BrowserHostProvider.runsAgentCode("frame.evaluate", host))
        #expect(BrowserHostProvider.runsAgentCode("cookies.set", unnamed))
        #expect(BrowserHostProvider.runsAgentCode("cookies.clear", unnamed))
        for method in ["cookies.get", "input.mouse", "input.key", "tab.screenshot", "tab.navigate", "frames.list"] {
            #expect(!BrowserHostProvider.runsAgentCode(method, unnamed), "\(method)")
        }
    }

    @Test func capturesAreTheScreenshotAndThePDF() {
        #expect(BrowserHostProvider.capturesPage("tab.screenshot"))
        #expect(BrowserHostProvider.capturesPage("tab.pdf"))
        #expect(!BrowserHostProvider.capturesPage("frame.evaluate"))
        #expect(!BrowserHostProvider.capturesPage("tab.info"))
    }
}
