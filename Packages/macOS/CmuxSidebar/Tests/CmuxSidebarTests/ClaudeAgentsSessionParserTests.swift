import Foundation
import Testing

@testable import CmuxSidebar

@Suite("ClaudeAgentsSessionParser")
struct ClaudeAgentsSessionParserTests {
    @Test("Maps a representative claude agents --json payload")
    func mapsRepresentativePayload() {
        let json = """
        [
          {
            "id": "8e89cfdd",
            "cwd": "/repo/.claude/worktrees/feature",
            "kind": "background",
            "startedAt": 1781774127358,
            "sessionId": "8e89cfdd-da22-4e97-be61-2630364ef5b1",
            "name": "theme translation",
            "status": "busy",
            "state": "blocked",
            "pid": 93132,
            "waitingFor": "permission prompt"
          },
          {
            "pid": 81685,
            "cwd": "/repo",
            "kind": "interactive",
            "startedAt": 1781885175275,
            "sessionId": "250a28e4-dcd5-421d-b9bb-f39a6060f1b2",
            "status": "idle"
          }
        ]
        """
        let agents = ClaudeAgentsSessionParser.parse(Data(json.utf8))

        #expect(agents.count == 2)

        let background = agents[0]
        #expect(background.id == "8e89cfdd")
        #expect(background.cwd == "/repo/.claude/worktrees/feature")
        #expect(background.kind == "background")
        #expect(background.name == "theme translation")
        #expect(background.state == "blocked")
        #expect(background.status == "busy")
        #expect(background.pid == 93132)
        #expect(background.startedAt == 1_781_774_127_358)
        #expect(background.waitingFor == "permission prompt")

        let interactive = agents[1]
        #expect(interactive.id == nil)
        #expect(interactive.kind == "interactive")
        #expect(interactive.state == nil)
        #expect(interactive.status == "idle")
    }

    @Test("Drops entries without a cwd instead of failing the batch")
    func dropsEntriesMissingCwd() {
        let json = """
        [
          { "kind": "background", "state": "done" },
          { "cwd": "/keep", "kind": "background", "state": "done" }
        ]
        """
        let agents = ClaudeAgentsSessionParser.parse(Data(json.utf8))
        #expect(agents.count == 1)
        #expect(agents.first?.cwd == "/keep")
    }

    @Test("Non-JSON output yields an empty array")
    func nonJSONYieldsEmpty() {
        let agents = ClaudeAgentsSessionParser.parse(Data("claude: command not found".utf8))
        #expect(agents.isEmpty)
    }
}
