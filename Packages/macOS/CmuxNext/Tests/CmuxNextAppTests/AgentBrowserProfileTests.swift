import CmuxNextActions
import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

/// openBrowser's optional `profile`: "agent" asks for the clean agent
/// profile (no extensions, no cookies shared with the person's profiles), or
/// the id of an existing profile (plans/cmux-next/passwords.md, section 3.4).
@MainActor @Suite struct AgentBrowserProfileTests {
    @Test func openBrowserDeclaresTheOptionalProfileArgument() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "openBrowser" })
        let argument = try #require(descriptor.arguments.first { $0.name == "profile" })
        #expect(!argument.isRequired)
    }

    @Test func requestsParse() {
        #expect(AgentBrowserProfile.request(nil) == .cascade)
        #expect(AgentBrowserProfile.request("") == .cascade)
        #expect(AgentBrowserProfile.request("agent") == .agent)
        #expect(AgentBrowserProfile.request("Agent") == .agent)
        #expect(AgentBrowserProfile.request("default") == .explicit("default"))
        let id = "0f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b"
        #expect(AgentBrowserProfile.request(id) == .explicit(id))
        #expect(AgentBrowserProfile.request("0F1E2D3C-4B5A-4987-8A6B-5C4D3E2F1A0B") == nil, "ids are lowercase")
        #expect(AgentBrowserProfile.request("work") == nil)
    }

    /// The agent profile has one fixed id, so every agent request finds the same profile.
    @Test func theAgentProfileIdIsAValidFixedProfileId() {
        #expect(BrowserProfileRecord.isValidID(AgentBrowserProfile.id))
        #expect(AgentBrowserProfile.id != BrowserProfileRecord.defaultID)
    }

    /// The agent refusal tells the agent how to get a clean tab.
    @Test func theExtensionRefusalNamesTheAgentProfile() throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://a.example/")))
        tab.installMockExtensions([BrowserExtensionInfo(id: "bw", name: "Bitwarden", path: "/ext/bw")])
        let access = AgentExtensionAccess { _ in ["host_permissions": ["<all_urls>"]] }
        let error = try #require(AppBrowserPage.agentExtensionRefusal(.evaluate("1"), target: nil, page: tab, allowedByPerson: false, access: access))
        #expect(error.message.contains("profile \"agent\""))
    }
}
