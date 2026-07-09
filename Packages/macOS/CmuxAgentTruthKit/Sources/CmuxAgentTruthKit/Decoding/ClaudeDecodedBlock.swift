import CmuxAgentReplica
import Foundation

struct ClaudeDecodedBlock: Hashable, Sendable {
    let kind: EntryKind
    let summary: String

    init(kind: EntryKind, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}
