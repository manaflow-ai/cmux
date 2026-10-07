/// What a Live Activity follows: a task or a terminal on one host
/// (a0-rpc.md 5.8). The owner matches feed items by their `context`.
public struct AgentActivitySubject: Codable, Hashable, Sendable {
    public var host: String
    public var task: String?
    public var terminal: String?

    public init(host: String, task: String? = nil, terminal: String? = nil) {
        self.host = host
        self.task = task
        self.terminal = terminal
    }
}
