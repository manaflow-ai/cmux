import CmuxAgentReplica
import Foundation

struct ClaudeDecodedBlock: Hashable, Sendable {
    let summary: String
    let payload: EntryPayload

    var kind: EntryKind {
        payload.kind
    }

    init(summary: String, payload: EntryPayload) {
        self.summary = summary
        self.payload = payload
    }
}
