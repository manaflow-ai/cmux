import CmuxNextBrowser
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// Agent page operations refuse a tab whose profile has an enabled extension
/// that can reach the page, unless the person allowed agents in that tab
/// (plans/cmux-next/passwords.md, section 3.4).
@MainActor @Suite struct AgentExtensionRefusalTests {
    func page(_ url: String = "https://accounts.example.com/login") -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: url)))
        tab.installMockExtensions([BrowserExtensionInfo(id: "bw", name: "Bitwarden", path: "/ext/bw")])
        return tab
    }

    let rule = AgentExtensionAccess { path in path == "/ext/bw" ? ["host_permissions": ["<all_urls>"]] : nil }

    func refusal(_ operation: BrowserPageOperation, _ tab: MockBrowserTab, target: String? = nil, allowed: Bool = false) -> ControlError? {
        AppBrowserPage.agentExtensionRefusal(operation, target: target.flatMap(URL.init(string:)), page: tab, allowedByPerson: allowed, access: rule)
    }

    @Test func everyPageOperationOnSuchATabIsRefusedWithATypedReason() throws {
        let tab = page()
        for operation in [BrowserPageOperation.evaluate("1"), .reload, .back, .forward] {
            let error = try #require(refusal(operation, tab))
            #expect(error.code == "forbidden")
            #expect(error.data?.objectValue?["reason"]?.stringValue == "extension_host_access")
            #expect(error.data?.objectValue?["extensions"] == .array([.string("Bitwarden")]))
        }
        #expect(refusal(.state, tab) == nil, "state reads no page content")
    }

    @Test func navigateChecksTheTarget() {
        let blank = page("about:blank")
        #expect(refusal(.navigate("https://a.test/"), blank, target: "https://a.test/")?.code == "forbidden")
        #expect(refusal(.evaluate("1"), blank) == nil, "a blank page has nothing to read")
    }

    @Test func aPersonsOverrideAllowsTheTab() {
        #expect(refusal(.evaluate("1"), page(), allowed: true) == nil)
    }

    @Test func theOverrideIsPerTabAndEndsWithTheTab() {
        let cache = TabContentCache(daemon: DaemonService())
        cache.allowAgentWithExtensions("tab")
        #expect(cache.agentMayUseExtensionTab("tab"))
        #expect(!cache.agentMayUseExtensionTab("other"))
        cache.install(page(), for: "tab")
        cache.release("tab")
        #expect(!cache.agentMayUseExtensionTab("tab"))
    }
}
