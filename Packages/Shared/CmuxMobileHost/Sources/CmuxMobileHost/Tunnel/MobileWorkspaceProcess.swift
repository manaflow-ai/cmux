/// A process running under one of the user's workspace terminals.
public struct MobileWorkspaceProcess: Hashable, Sendable {
    public var pid: Int32
    /// The workspace (`ws_…`) whose terminal started it.
    public var workspace: String?
    public var name: String?

    public init(pid: Int32, workspace: String? = nil, name: String? = nil) {
        self.pid = pid
        self.workspace = workspace
        self.name = name
    }
}
