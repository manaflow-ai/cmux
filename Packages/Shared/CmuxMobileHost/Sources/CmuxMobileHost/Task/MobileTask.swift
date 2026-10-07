/// One task the Mac's runner started (task.schema.json `Task`).
public struct MobileTask: Hashable, Sendable, Codable {
    public var id: String
    public var host: String
    public var workspace: String?
    public var tab: String?
    public var agent: String
    public var state: MobileTaskState
    public var title: String?
    /// Unix milliseconds.
    public var createdAt: Int64

    public init(id: String, host: String, workspace: String? = nil, tab: String? = nil, agent: String,
                state: MobileTaskState, title: String? = nil, createdAt: Int64) {
        self.id = id
        self.host = host
        self.workspace = workspace
        self.tab = tab
        self.agent = agent
        self.state = state
        self.title = title
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, host, workspace, tab, agent, state, title
        case createdAt = "created_at"
    }

    /// The record with every field but `state` (what a `task.state.set` cannot change).
    var structure: MobileTask {
        var copy = self
        copy.state = .queued
        return copy
    }
}
