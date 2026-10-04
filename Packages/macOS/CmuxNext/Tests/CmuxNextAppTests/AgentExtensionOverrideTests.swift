import CmuxNextActions
import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

/// "Allow Agents in This Tab…": person-only, confirmed by a native warning
/// that names the extensions (plans/cmux-next/passwords.md, section 3.4).
@MainActor @Suite struct AgentExtensionOverrideTests {
    @Test func theActionIsPersonOnlyAndConfirmed() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "browser.allowAgentWithExtensions" })
        #expect(descriptor.isPersonOnly)
        #expect(descriptor.isDestructive)
    }

    @Test func theWarningNamesTheExtensions() {
        let prompt = AgentExtensionHandlers.prompt(blockers: ["Bitwarden", "LastPass"])
        #expect(prompt.body.contains("Bitwarden") && prompt.body.contains("LastPass"))
        #expect(prompt.button == AgentExtensionStrings.button)
        #expect(AgentExtensionHandlers.prompt(blockers: []).body == AgentExtensionStrings.bodyNone)
    }

    @Test func blockerNamesComeFromTheTabsProfile() {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/")))
        tab.installMockExtensions([
            BrowserExtensionInfo(id: "bw", name: "Bitwarden", path: "/ext/bw"),
            BrowserExtensionInfo(id: "plain", name: "Plain", path: "/ext/plain"),
        ])
        let access = AgentExtensionAccess { path in
            path == "/ext/bw" ? ["host_permissions": ["<all_urls>"]] : ["permissions": ["storage"]]
        }
        #expect(AgentExtensionHandlers.blockerNames(tab, access: access) == ["Bitwarden"])
    }
}
