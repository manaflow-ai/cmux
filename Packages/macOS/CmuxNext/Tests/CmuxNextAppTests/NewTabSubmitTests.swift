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

    func plan(_ text: String, _ mode: NewTabIntent.Mode = .ask, agent: String? = nil) -> NewTabSubmit {
        NewTabSubmit.plan(text: text, mode: mode, agent: agent, resolver: resolver, home: home)
    }

    @Test func eachIntentBecomesItsTab() {
        #expect(plan("") == .page)
        #expect(plan("!git status") == .terminal(command: "git status"))
        #expect(plan("github.com") == .browser(URL(string: "https://github.com")!))
        #expect(plan("fix the build") == .chat(prompt: "fix the build", harness: nil))
        #expect(plan("fix the build", agent: "codex") == .chat(prompt: "fix the build", harness: "codex"))
        #expect(plan("node.js", .search) == .browser(resolver.searchEngine.searchURL(for: "node.js")!))
    }

    @Test func theActionReachesPaletteCLIAndMCPWithTypedArguments() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == NewTabSubmit.action })
        #expect(action.cliName == "tab new-from-text")
        #expect(action.surfaces.contains(.palette))
        #expect(action.arguments.map(\.name) == ["text", "mode", "agent"])
        #expect(action.arguments.map(\.isRequired) == [true, false, false])
    }
}
