/// The Cloud chat a Mac tab shows in place (cmux#47677): its machine, tab and the workspace that holds it there.
/// Kept across relaunches as JSON (`machine`, `key`, `workspace`).
public struct AgentTabCloudFront: Codable, Hashable, Sendable {
    public let machine: String
    public let key: String
    public let workspace: String

    public init(machine: String, key: String, workspace: String) {
        (self.machine, self.key, self.workspace) = (machine, key, workspace)
    }

    public var tab: AgentTabKey { AgentTabKey(machine: machine, key: key) }
}
