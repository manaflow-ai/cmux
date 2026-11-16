/// The project list of a chat on another machine: its workspaces' folders, then the folders the
/// machine lists itself, each once, in that order.
public nonisolated struct AgentRemoteStartFolders: Sendable {
    public let listed: [String]
    public let machine: [String]

    public init(listed: [String], machine: [String]) {
        self.listed = listed
        self.machine = machine
    }

    public var merged: [String] {
        var seen = Set<String>()
        return (listed + machine).filter { seen.insert($0).inserted }
    }
}
