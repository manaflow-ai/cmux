import CmuxAgentReplica

struct TranscriptTurnAccumulator: Sendable {
    let id: TranscriptTurnID
    var user: EntryContext?
    var events: [EntryContext]

    init(id: TranscriptTurnID, user: EntryContext? = nil) {
        self.id = id
        self.user = user
        events = []
    }

    mutating func append(_ context: EntryContext) {
        events.append(context)
    }
}
