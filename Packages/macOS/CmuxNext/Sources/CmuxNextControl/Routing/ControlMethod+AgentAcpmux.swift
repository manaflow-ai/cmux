import Foundation

extension ControlMethod {
    /// `agent.acpmux` (#23026): where the app's own acpmux listens, the one its agent chat tabs
    /// use. `cmux agents chat new` starts a chat there, so a caller whose own acpmux is another
    /// one (a Chief turn runs in its home's) starts a chat the app shows as an ordinary chat, as
    /// New Agent Chat and a first message do, not a subagent. Read only: `{socket_path, home}`,
    /// or null when `locate` finds none (a build without acpmux).
    public static func agentAcpmux(
        _ locate: @escaping @MainActor @Sendable () -> (socketPath: String, home: String)?
    ) -> ControlMethod {
        .mainActor("agent.acpmux") { _ in
            guard let found = locate() else { return .value(.null) }
            return .value(["socket_path": .string(found.socketPath), "home": .string(found.home)])
        }
    }
}
