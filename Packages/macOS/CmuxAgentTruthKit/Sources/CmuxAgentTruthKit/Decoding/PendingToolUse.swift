import CmuxAgentReplica
import Foundation

struct PendingToolUse: Hashable, Sendable {
    let kind: EntryKind
    let summary: String
    let raw: String

    init(kind: EntryKind, summary: String, raw: String) {
        self.kind = kind
        self.summary = summary
        self.raw = raw
    }
}
