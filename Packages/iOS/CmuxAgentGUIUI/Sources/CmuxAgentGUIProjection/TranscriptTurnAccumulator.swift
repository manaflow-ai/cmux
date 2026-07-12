import CmuxAgentReplica

struct TranscriptTurnAccumulator: Sendable {
    let id: TranscriptTurnID
    var user: EntryContext?
    var activity: [EntryContext]
    var assistant: EntryContext?
    private var assistantActivityIndex: Int?

    init(id: TranscriptTurnID, user: EntryContext? = nil) {
        self.id = id
        self.user = user
        activity = []
    }

    mutating func append(_ context: EntryContext) {
        if case .agentProse = context.entry.content.payload {
            if let assistant {
                let index = min(assistantActivityIndex ?? activity.count, activity.count)
                activity.insert(assistant, at: index)
            }
            assistant = context
            assistantActivityIndex = activity.count
        } else {
            activity.append(context)
        }
    }
}
