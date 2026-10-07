/// What the mobile host needs from the cmux-tui daemon. The host owns no
/// entity: terminal facts come from the session host, layout from the
/// workspace store. The app implements this over `DaemonConnection` and
/// `TerminalAttachment`; tests use a fake.
public protocol MobileDaemon: Sendable {
    /// The current tree, projected to `workspace:<host>` state.
    func workspaceState() async throws -> MobileWorkspaceState
    /// Yields once per tree change, until the subscriber stops iterating.
    func workspaceChanges() async -> AsyncStream<Void>
    /// Runs one op the policy allowed. Throws `MobileDaemonError` with a
    /// family code (for example `workspace.not_found`) on refusal.
    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult
    /// A snapshot attach for one viewer (`terminal-snapshot-v1`).
    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment
}
