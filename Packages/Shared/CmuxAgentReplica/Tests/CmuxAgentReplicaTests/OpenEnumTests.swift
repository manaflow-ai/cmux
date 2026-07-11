import Foundation
import Testing
@testable import CmuxAgentReplica

@Suite struct OpenEnumTests {
    @Test func agentAndEntryKindsDecodeFailOpen() throws {
        let decoder = JSONDecoder()
        let agent = try decoder.decode(AgentKind.self, from: Data(#""future-agent""#.utf8))
        let entry = try decoder.decode(EntryKind.self, from: Data(#""future-entry""#.utf8))

        #expect(agent == .unknown("future-agent"))
        #expect(entry == .unknown("future-entry"))
    }
}
