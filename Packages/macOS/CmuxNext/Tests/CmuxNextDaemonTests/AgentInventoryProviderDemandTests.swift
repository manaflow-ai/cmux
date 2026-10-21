import Foundation
import Testing
@testable import CmuxNextDaemon

struct AgentInventoryProviderDemandTests {
    @Test(arguments: ["9007199254740993", "18446744073709551615"])
    func demandKeepsExactSequenceBeforeGenericJSON(decimal: String) {
        let line = Data("{\"event\":\"apps-agent-inventory-demand\",\"sequence\":\(decimal),\"enabled\":true}".utf8)
        let event = DaemonEvent.decode(name: "apps-agent-inventory-demand", line: line)
        guard case .unknown(_, let payload) = event else { Issue.record("demand was not retained"); return }
        #expect(payload["sequence"] == .string(decimal))
        #expect(payload["enabled"] == .bool(true))
    }
}
