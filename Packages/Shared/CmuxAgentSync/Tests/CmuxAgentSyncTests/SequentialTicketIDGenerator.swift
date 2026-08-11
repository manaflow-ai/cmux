import CmuxAgentSync
import Foundation

final class SequentialTicketIDGenerator: AgentSyncTicketIDGenerator, @unchecked Sendable {
    private nonisolated(unsafe) var nextValue: UInt64 = 1

    func nextTicketID() -> UUID {
        defer { nextValue += 1 }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llu", nextValue))!
    }
}
