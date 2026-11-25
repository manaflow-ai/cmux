/// A workspace that does not exist yet and gets made with its first terminal: once the connection took it
/// (``DaemonConnection/makesWorkspace(with:)``), its first-terminal request for ``key``
/// (``DaemonConnection/createTerminalWaitingForStart(_:)``) asks the daemon to make the workspace too
/// (`create-terminal-workspace-v1`), so the two are one request. A daemon without the capability does not take
/// it (its caller sends `create-workspace` first).
///
/// ```swift
/// if await !connection.makesWorkspace(with: NewTerminalWorkspace(key: key, name: "shell")) {
///     try await connection.createWorkspaceWaitingForReply(name: "shell", key: key)
/// }
/// try await connection.createTerminalWaitingForStart(in: key, cwd: nil)
/// ```
public struct NewTerminalWorkspace: Sendable, Equatable {
    /// The key of the workspace to make.
    public let key: WorkspaceKey
    /// Its name; nil: the daemon names it.
    public let name: String?

    /// - Parameters:
    ///   - key: The key of the workspace to make.
    ///   - name: Its name; nil: the daemon names it.
    public init(key: WorkspaceKey, name: String?) {
        self.key = key
        self.name = name
    }

    /// `request` asking for this workspace too, when it is a keyed first terminal of ``key``; else `request`.
    public func applied(to request: CreateTerminalRequest) -> CreateTerminalRequest {
        guard request.workspace == .key(key), request.mutation != nil, request.terminalID != nil else { return request }
        var request = request
        request.createWorkspace = true
        request.workspaceName = name
        return request
    }
}
