/// Claude Code's persisted representation of one task-tool item.
struct ClaudeTaskRecord: Decodable {
    let id: String
    let subject: String
    let activeForm: String?
    let status: String

    var canonicalState: WorkstreamTaskTodo.State? {
        switch status {
        case "pending": .pending
        case "in_progress": .inProgress
        case "completed": .completed
        case "deleted": nil
        default: nil
        }
    }
}
