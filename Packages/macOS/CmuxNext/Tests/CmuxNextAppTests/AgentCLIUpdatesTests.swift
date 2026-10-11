@testable import CmuxNextApp
import CmuxNextSettings
import Foundation
import Testing

/// One-click agent CLI updates (cx-ny85): from the daemon's `_acpmux/harness/health` answer,
/// Settings > Agents (Update, Update All) and the palette's Update Agent CLIs type the same lines.
/// An outdated harness types its own update, quoted; one that needs sudo, a sudo program, a word no
/// shell quotes alike, or an up-to-date one types nothing; two harnesses from one package update once.
@MainActor struct AgentCLIUpdatesTests {
    static let answer = #"""
    {"harnesses": [
      {"id": "codex", "outdated": true, "update": {"argv": ["npm", "install", "-g", "@openai/codex@latest"], "command": "npm install -g @openai/codex@latest", "elevated": false}},
      {"id": "codex-acp", "outdated": true, "update": {"argv": ["npm", "install", "-g", "@openai/codex@latest"], "command": "npm install -g @openai/codex@latest", "elevated": false}},
      {"id": "claude", "outdated": true, "update": {"argv": ["/Users/me/My Tools/claude", "update"], "command": "'/Users/me/My Tools/claude' update", "elevated": false}},
      {"id": "opencode", "outdated": true, "update": {"argv": ["npm", "install", "-g", "opencode-ai@latest"], "command": "sudo npm install -g opencode-ai@latest", "elevated": true}},
      {"id": "rooted", "outdated": true, "update": {"argv": ["/usr/bin/sudo", "npm", "install", "-g", "x@latest"], "command": "sudo npm install -g x@latest", "elevated": false}},
      {"id": "quoted", "outdated": true, "update": {"argv": ["npm", "install", "-g", "it's@latest"], "command": "npm install -g it's@latest", "elevated": false}},
      {"id": "unsaid", "outdated": true, "update": {"argv": ["npm", "install", "-g", "y@latest"], "command": "npm install -g y@latest"}},
      {"id": "gemini", "outdated": false, "update": {"argv": ["brew", "upgrade", "gemini-cli"], "command": "brew upgrade gemini-cli", "elevated": false}},
      {"id": "grok", "outdated": true, "update": null}
    ]}
    """#

    @Test func oneClickTypesEachOutdatedHarnessesOwnUpdateOnceAndNeverSudo() throws {
        let rows = try #require(AgentCLIUpdates.rows(Data(Self.answer.utf8)))
        #expect(rows.count == 9)
        #expect(AgentCLIUpdates.line(try #require(rows["codex"])) == "'npm' 'install' '-g' '@openai/codex@latest'")
        for id in ["opencode", "rooted", "quoted", "unsaid", "gemini", "grok"] {
            #expect(AgentCLIUpdates.line(try #require(rows[id])) == nil, "\(id) must not be typed")
        }
        let ordered = ["claude", "codex", "codex-acp", "gemini", "grok", "opencode", "quoted", "rooted", "unsaid"].compactMap { rows[$0] }
        #expect(AgentCLIUpdates.allLine(ordered) == "'/Users/me/My Tools/claude' 'update'; 'npm' 'install' '-g' '@openai/codex@latest'")
        #expect(AgentCLIUpdates.allLine(ordered.filter { $0["outdated"]?.boolValue == false }) == nil)
    }
}
