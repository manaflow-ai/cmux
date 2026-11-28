import Foundation
@testable import CmuxNextAgentPane
import CmuxNextSettings
import Testing

struct AgentProjectPaletteTests {
    @Test func decodesAProjectPageAndMapsItsRowActivation() throws {
        let params = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "id": "opening", "push": true,
          "model": {
            "page": "github", "title": "Add project", "placeholder": "Search repositories",
            "scope": {"label": "GitHub", "icon": "github"}, "query": "api",
            "rows": [
              {"id": "acme/api", "label": "acme/api", "icon": "github", "status": "Private", "enabled": true},
              {"id": "notice", "label": "Loading", "enabled": false}
            ]
          }
        }
        """#.utf8))
        let request = try #require(AgentProjectPaletteRequest(method: "projectPalette.update", params: params))
        guard case .update(let page, true) = request.operation else {
            Issue.record("Expected a page update")
            return
        }
        #expect(page.scope?.label == "GitHub")
        #expect(page.rows.first?.status == "Private")
        let pick = try #require(page.rows.first?.activation(in: page.page, query: page.query))
        #expect(pick.payload(session: request.id) == .object([
            "session": .string("opening"), "type": .string("pick"), "page": .string("github"), "id": .string("acme/api")
        ]))
        #expect(page.rows.last?.activation(in: page.page, query: page.query) == nil)
    }

    @Test func mapsTheURLFieldAndBackToTheirTextEvents() throws {
        let row = try JSONDecoder().decode(AgentProjectPalettePage.Row.self, from: Data(#"""
        {"id": "submit", "label": "Clone", "enabled": true}
        """#.utf8))
        let url = "https://example.com/owner/project.git"
        let submit = try #require(row.activation(in: .url, query: url))
        #expect(submit.payload(session: "a") == .object([
            "session": .string("a"), "type": .string("submit"), "page": .string("url"), "text": .string(url)
        ]))
        #expect(AgentProjectPaletteEvent.back(.machines, "mac").payload(session: "a") == .object([
            "session": .string("a"), "type": .string("back"), "page": .string("machines"), "text": .string("mac")
        ]))
    }

    @Test func rejectsAnExtraFolderPage() throws {
        let params = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "id": "opening", "push": true,
          "model": {
            "page": "extra", "title": "Add project", "placeholder": "Search folders",
            "scope": {"label": "Folder", "icon": "folder"}, "query": "", "rows": []
          }
        }
        """#.utf8))
        #expect(AgentProjectPaletteRequest(method: "projectPalette.update", params: params) == nil)
    }

    /// cmux#55104: a palette closed on its GitHub page (Connect to GitHub's sheet took the keys) may be shown again once
    /// with no gesture, soon after; any other close, or a second show, is the person's to make.
    @Test func resumesOnceAfterAConnectClosedTheGitHubPage() {
        var resume = AgentProjectPaletteResume()
        #expect(!resume.take(at: 10))
        resume.picked("\0connection", on: .github)
        resume.closed(on: .github, at: 10)
        #expect(resume.take(at: 70))
        #expect(!resume.take(at: 71))

        // Escape or a click elsewhere on the GitHub page, with no Connect: nothing to resume.
        resume.closed(on: .github, at: 100)
        #expect(!resume.take(at: 101))

        // A repository pick, or a Connect on another page.
        resume.picked("manaflow-ai/cmux", on: .github)
        resume.closed(on: .github, at: 110)
        #expect(!resume.take(at: 111))
        resume.picked("\0connection", on: .add)
        resume.closed(on: .add, at: 120)
        #expect(!resume.take(at: 121))

        // The pick counts for the one close after it.
        resume.picked("\0more", on: .github)
        resume.closed(on: .github, at: 200)
        resume.closed(on: .github, at: 201)
        #expect(!resume.take(at: 202))

        resume.picked("\0addAccount", on: .github)
        resume.closed(on: .github, at: 300)
        #expect(!resume.take(at: 300 + AgentProjectPaletteResume.window + 1))
        resume.picked("\0connection", on: .github)
        resume.closed(on: .github, at: 400)
        #expect(!resume.take(at: 399))
    }
}
