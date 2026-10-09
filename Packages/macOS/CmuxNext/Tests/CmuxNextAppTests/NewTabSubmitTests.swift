import CmuxNextActions
import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

/// `newTab.submit` (plans/cmux-next/new-tab.md section 5): the CLI, MCP and
/// palette path of the new tab field, deciding as the field does.
@Suite struct NewTabSubmitTests {
    let resolver = OmniboxResolver(searchEngine: .google)
    let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    func plan(_ text: String, search: Bool = false, agent: String? = nil) -> NewTabSubmit {
        NewTabSubmit.plan(text: text, search: search, agent: agent, resolver: resolver, home: home)
    }

    @Test func eachIntentBecomesItsTab() {
        #expect(plan("") == .page)
        #expect(plan("!git status") == .terminal(command: "git status"))
        #expect(plan("github.com") == .browser(URL(string: "https://github.com")!))
        #expect(plan("fix the build") == .chat(prompt: "fix the build", harness: nil))
        #expect(plan("fix the build", agent: "codex") == .chat(prompt: "fix the build", harness: "codex"))
        // A web search is the explicit choice (R86), even for an address-like text.
        #expect(plan("node.js", search: true) == .browser(resolver.searchEngine.searchURL(for: "node.js")!))
        #expect(plan("github.com", search: true) == .browser(resolver.searchEngine.searchURL(for: "github.com")!))
        #expect(plan("!ls", search: true) == .terminal(command: "ls"))
    }

    /// The palette (a user's typing) fixes `.con` as the omnibar does; CLI,
    /// MCP and scripts load what they were given.
    @Test func paletteTextFixesHostTyposButAgentTextDoesNot() {
        let palette = { (text: String) in
            NewTabSubmit.plan(text: text, search: false, agent: nil, resolver: OmniboxResolver(), home: self.home, fixesHostTypos: true)
        }
        #expect(palette("example.con/docs?q=1") == .browser(URL(string: "https://example.com/docs?q=1")!))
        #expect(palette("example.com'") == .browser(URL(string: "https://example.com")!))
        #expect(palette("!ls example.con") == .terminal(command: "ls example.con"))
        #expect(plan("example.con") == .browser(URL(string: "https://example.con")!))
        #expect(NewTabSubmit.plan(text: "example.con", search: true, agent: nil, resolver: resolver, home: home, fixesHostTypos: true)
            == .browser(resolver.searchEngine.searchURL(for: "example.con")!))
    }

    @Test func theActionReachesPaletteCLIAndMCPWithTypedArguments() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == NewTabSubmit.action })
        #expect(action.cliName == "tab new-from-text")
        #expect(action.surfaces.contains(.palette))
        #expect(action.arguments.map(\.name) == ["text", "search", "agent"])
        #expect(action.arguments.map(\.isRequired) == [true, false, false])
    }
}
