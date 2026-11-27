/// `agent_chat.list` (`cmux.agent_chat.list()`, scope `agent_chat:read`): the agent chats the
/// sidebar shows, with title, state, folder and times, so a customize section can draw them as a
/// thread list of its own. Answers `{chats: [...]}` in the order `chats` gives them; the script
/// sorts and groups. Reads only what the app already holds (its acpmux lanes): no session starts,
/// no transcript is read.
public nonisolated struct AgentChatAppOps: AppHostCapabilityHandler {
    private let chats: @MainActor @Sendable () -> [AgentChatSummary]

    /// - Parameter chats: The chats now, read at each call (the app's lanes; a fixture in captures).
    public init(chats: @escaping @MainActor @Sendable () -> [AgentChatSummary]) {
        self.chats = chats
    }

    /// The capability family supplied on the verified-app provider channel.
    public var families: Set<String> { ["agent_chat"] }

    /// Answers `agent_chat.list` with `{chats: [{id, title, harness, state, unread, project, cwd,
    /// workspace, machine, step, error, since_ms, updated_ms, created_ms, pull_requests}]}`.
    /// - Parameter request: The supervisor-admitted call.
    /// - Returns: Every chat in the script's shape.
    /// - Throws: `operation.unsupported` for another op, `validation.invalid` for any param.
    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.op == "agent_chat.list" else { throw .unsupported(request.op) }
        guard request.params == .null || request.params.objectValue?.isEmpty == true else {
            throw AppHostCapabilityError(code: "validation.invalid", message: "agent_chat.list takes no params")
        }
        return ["chats": .array(await chats().map(\.appJSON))]
    }
}
