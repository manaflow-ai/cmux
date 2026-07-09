import CmuxAgentReplica
import Foundation

struct PendingToolUse: Hashable, Sendable {
    let payload: EntryPayload
    let raw: String

    init(payload: EntryPayload, raw: String) {
        self.payload = payload
        self.raw = raw
    }
}
