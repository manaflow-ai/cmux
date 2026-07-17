import CmuxMobileRPC
import Foundation
import Testing

@Suite("MobileAgentLaunchOptionsResponse")
struct MobileAgentLaunchOptionsResponseTests {
    @Test("Decodes the full wire shape")
    func decodesFullShape() throws {
        let data = Data("""
        {
          "agents": [
            {"id": "claude", "name": "Claude Code", "installed": true},
            {"id": "codex", "name": "Codex", "installed": false}
          ],
          "directories": [
            {"path": "/Users/dev/Projects/app"},
            {"path": "/Users/dev"}
          ],
          "default_directory": "/Users/dev/Projects/app"
        }
        """.utf8)
        let response = try MobileAgentLaunchOptionsResponse.decode(data)
        #expect(response.agents.map(\.id) == ["claude", "codex"])
        #expect(response.agents.map(\.installed) == [true, false])
        #expect(response.directories.map(\.path) == ["/Users/dev/Projects/app", "/Users/dev"])
        #expect(response.defaultDirectory == "/Users/dev/Projects/app")
    }

    @Test("Missing fields decode to safe defaults")
    func decodesSparsePayload() throws {
        let response = try MobileAgentLaunchOptionsResponse.decode(Data("{}".utf8))
        #expect(response.agents.isEmpty)
        #expect(response.directories.isEmpty)
        #expect(response.defaultDirectory == nil)
    }

    @Test("Agent name and installed default when omitted")
    func agentDefaults() throws {
        let data = Data("""
        {"agents": [{"id": "claude"}]}
        """.utf8)
        let response = try MobileAgentLaunchOptionsResponse.decode(data)
        #expect(response.agents.first?.name == "claude")
        #expect(response.agents.first?.installed == false)
    }
}
