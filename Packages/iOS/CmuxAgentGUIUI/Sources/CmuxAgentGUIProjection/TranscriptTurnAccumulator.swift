import CmuxAgentReplica

struct TranscriptTurnAccumulator: Sendable {
    let id: TranscriptTurnID
    var user: EntryContext?
    var entries: [EntryContext]

    init(id: TranscriptTurnID, user: EntryContext? = nil) {
        self.id = id
        self.user = user
        entries = []
    }

    mutating func append(_ context: EntryContext) {
        entries.append(context)
    }
}
