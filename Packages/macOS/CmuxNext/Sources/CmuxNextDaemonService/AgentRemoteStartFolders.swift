/// The project list of a chat on another machine: its workspaces' folders, then the folders the
/// machine lists itself, each once, in that order.
public nonisolated enum AgentRemoteStartFolders {
    public static func merged(listed: [String], machine: [String]) -> [String] {
        var seen = Set<String>()
        return (listed + machine).filter { seen.insert($0).inserted }
    }
}
