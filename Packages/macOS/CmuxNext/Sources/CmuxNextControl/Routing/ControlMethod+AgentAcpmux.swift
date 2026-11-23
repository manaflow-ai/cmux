import Foundation

extension ControlMethod {
    /// `agent.acpmux` (#23026): where the app's own acpmux listens, the one its agent chat tabs
    /// use. `cmux agents chat new` starts a chat there, so a caller whose own acpmux is another
    /// one (a Chief turn runs in its home's) starts a chat the app shows as an ordinary chat, as
    /// New Agent Chat and a first message do, not a subagent. Read only: `{socket_path, home}`,
    /// or null when `locate` finds none (a build without acpmux).
    ///
    /// Off the main actor: `cmux chat new` asks this before it starts the chat, so a main
    /// actor busy with a daemon restart or a tab open held every new chat's start behind it
    /// (goal local-instant-start). `locate` reads only the bundle, the environment and files.
    public static func agentAcpmux(
        _ locate: @escaping @Sendable () -> (socketPath: String, home: String)?
    ) -> ControlMethod {
        .async("agent.acpmux") { _ in
            guard let found = locate() else { return .null }
            return ["socket_path": .string(found.socketPath), "home": .string(found.home)]
        }
    }
}
