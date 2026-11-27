public import CmuxNextActions
public import CmuxNextAgentActivity

/// The person's own reach into this Mac's Computer Use sessions from outside a window: the menu
/// bar item's Computer Use row reads the newest live session and takes it over or hands it back
/// (`activity_session_pause|resume`, user ops the host authenticates by its token). One request
/// per call over the helper's socket (``ComputerUseHelperDaemon/configuration``); nothing runs
/// between calls.
@MainActor
public final class ComputerUseUserSessions {
    public static let shared = ComputerUseUserSessions(configuration: { ComputerUseHelperDaemon.shared.configuration })

    private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?

    public init(configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?) {
        self.configuration = configuration
    }

    /// The live session that acted last; nil when none lives, no helper runs or it does not answer.
    public func newest() async -> ComputerUseLiveSession? {
        guard let result = try? await send("activity_sessions_list", ["status": "live"]) else { return nil }
        return ComputerUseLiveSession.live(from: result).first
    }

    /// ``newest()`` as the menu bar's Computer Use row reads it.
    public func menuBarSession() async -> MenuBarMenuState.ComputerUse.Session? {
        await newest().map { .init(id: $0.id, appName: $0.target?.appName, bundleID: $0.target?.bundleID, paused: $0.paused) }
    }

    /// Takes session `id` over (`paused`: the host rejects its acts) or hands it back.
    public func setPaused(_ id: String, _ paused: Bool) async throws {
        _ = try await send(paused ? "activity_session_pause" : "activity_session_resume", ["id": id])
    }

    private func send(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let configuration = configuration() else { throw AgentActivitySourceError.closed }
        return try await CuaSocketClient(configuration: configuration).send(method, args, deadline: .seconds(5))
    }
}
