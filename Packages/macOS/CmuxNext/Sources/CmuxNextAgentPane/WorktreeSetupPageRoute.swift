public import CmuxNextDaemon
public import CmuxNextPages
public import CmuxNextSettings

/// Settings > Agents > Worktree Setup (design/worktree-setup.md): `list`, `read {path}` and
/// `save {path, worktree}`, sent as the session host's `project.list`, `git.worktree.setup` and
/// `project.update` (field `worktree`) on the app's own connection (``WorktreeSetupClient``). The
/// session host refuses project and git operations from a page, so Settings reaches only these
/// three, and `save` runs only on the person's click. Thin: route only.
@MainActor
public final class WorktreeSetupPageRoute: PageProvider {
    public nonisolated static let prefix = "cmux.settings.worktree."
    /// The most projects the card lists.
    static let maximumProjects = 200

    private let connection: @MainActor () -> DaemonConnection?

    public init(connection: @escaping @MainActor () -> DaemonConnection?) {
        self.connection = connection
    }

    public func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard context.page == PageDescriptor.settings.id else { throw PageError.unknownOp(op) }
        let path = params["path"]?.stringValue.flatMap { $0.hasPrefix("/") ? $0 : nil }
        let operation: String
        var fields: [String: CmuxNextSettings.JSONValue] = [:]
        var key: String?
        switch op {
        case Self.prefix + "list":
            operation = "project.list"
            fields["limit"] = .number(Double(Self.maximumProjects))
        case Self.prefix + "read":
            guard let path else { throw PageError.invalidParams("path is required") }
            operation = "git.worktree.setup"
            fields["path"] = .string(path)
        case Self.prefix + "save":
            guard context.userGesture else {
                throw PageError(code: "cmux.settings.user_only", message: "only you can save a worktree setup")
            }
            guard let path, let worktree = params["worktree"],
                  let given = params["idempotency_key"]?.stringValue ?? context.opid else {
                throw PageError.invalidParams("path, worktree and idempotency_key are required")
            }
            operation = "project.update"
            fields = ["path": .string(path), "worktree": worktree]
            key = given
        default:
            throw PageError.unknownOp(op)
        }
        guard let connection = connection() else { throw PageError.closed }
        do {
            let sent = try await WorktreeSetupClient(connection: connection).send(
                operation: operation, params: try DaemonPageValue.daemonParams(fields), idempotencyKey: key)
            return try DaemonPageValue.pageValue(sent)
        } catch let error as DaemonError {
            throw DaemonPageValue.pageError(error)
        }
    }
}
