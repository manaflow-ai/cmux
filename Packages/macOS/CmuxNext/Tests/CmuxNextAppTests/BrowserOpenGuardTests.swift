import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// Every path that opens a browser tab from text shares openBrowser's guard
/// (BrowserOpenPlan): agents never open Chromium's own pages, a Chromium page
/// never becomes a WebKit tab, and an engine inferred from the URL is not
/// remembered as the user's choice.
@MainActor @Suite struct BrowserOpenGuardTests {
    private static func submitted(_ text: String, origin: ActionOrigin) throws -> BrowserOpenPlan.Outcome {
        let plan = NewTabSubmit.plan(text: text, search: false, agent: nil, resolver: OmniboxResolver(),
                                     home: URL(filePath: "/Users/me"))
        guard case .browser(let url) = plan else {
            Issue.record("\(text) is not a browser tab: \(plan)")
            return .refuse("")
        }
        let invocation = ActionInvocation(arguments: ["text": .string(text)], origin: origin)
        let open = try #require(NewTabSubmit.browserInvocation(url, from: invocation), "newTab.submit bypasses openBrowser")
        #expect(open.origin == origin)
        return BrowserOpenPlan.make(url: open["url"]?.stringValue, engine: open["engine"]?.stringValue, origin: open.origin)
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script])
    func agentsCannotOpenPrivilegedPagesThroughNewTabSubmit(_ origin: ActionOrigin) throws {
        for text in ["chrome://password-manager", "about:settings", "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html"] {
            #expect(try Self.submitted(text, origin: origin) == .refuse(MiscHandlerStrings.agentChromiumPage), "\(text)")
        }
    }

    @Test func thePersonOpensThemInChromium() throws {
        let outcome = try Self.submitted("chrome://password-manager", origin: .user)
        guard case .open(let plan) = outcome else { Issue.record("refused: \(outcome)"); return }
        #expect(plan.url?.absoluteString == "chrome://password-manager/")
        #expect(plan.engine == BrowserEngineTag.cef.rawValue)
    }

    @Test func agentsStillOpenWebPagesThroughNewTabSubmit() throws {
        guard case .open(let plan) = try Self.submitted("example.com", origin: .cli) else { Issue.record("refused"); return }
        #expect(plan.url?.absoluteString == "https://example.com")
    }

    @Test func anInferredEngineIsNotRememberedAsTheUsersChoice() {
        guard case .open(let plan) = BrowserOpenPlan.make(url: "chrome://version", engine: nil, origin: .user) else {
            Issue.record("refused"); return
        }
        #expect(plan.engine == BrowserEngineTag.cef.rawValue)
        #expect(plan.recordedEngine == nil)
        guard case .open(let explicit) = BrowserOpenPlan.make(url: "example.com", engine: "webkit", origin: .user) else {
            Issue.record("refused"); return
        }
        #expect(explicit.recordedEngine == "webkit")
    }

    @Test func chromiumPagesAndChromiumRequestsNeverBecomeSessionLocalWebKitTabs() throws {
        let page = try #require(URL(string: "chrome://extensions/"))
        #expect(!PaneBrowserTabOpener.allowsSessionLocalTab(url: page, requested: nil))
        #expect(!PaneBrowserTabOpener.allowsSessionLocalTab(url: nil, requested: BrowserEngineTag.cef.rawValue))
        #expect(PaneBrowserTabOpener.allowsSessionLocalTab(url: URL(string: "https://example.com/"), requested: nil))
        #expect(PaneBrowserTabOpener.allowsSessionLocalTab(url: nil, requested: nil))
    }
}
