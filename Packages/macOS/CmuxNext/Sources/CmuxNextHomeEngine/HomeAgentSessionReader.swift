import CmuxHomeCore
import CmuxNextAgentPane
import Foundation

/// Reads where the Chief's agents run now (plans/cmux-next/home-agent-pills-DESIGN.md, Identity): each
/// agent's session, place and epoch from the Chief's spawn records (`host/spawns` in the Chief home's
/// `optchat/memory.sqlite3`, a963), then its acpmux session's `movedTo` and `moveEpoch` (a964). Read at
/// each call; nothing is cached.
nonisolated struct HomeAgentSessionReader: Sendable {
    /// The Chief home's memory database (`<home>/optchat/memory.sqlite3`).
    let memory: URL
    /// The acpmux session summary's move, by session id; nil when acpmux has no such session.
    let move: @Sendable (String) async -> HomeAgentSessionMove?

    /// The reader of `home`'s Chief: its memory database and its acpmux (the app's own for a Chief on it).
    init(home: ChiefHome, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let acpmux = home.usesAppAcpmux ? AcpmuxEnvironment.appHome(userHome: userHome) : home.acpmuxHome
        let page = AcpmuxSessionPage(socketPath: AcpmuxEnvironment.socketPath(home: acpmux))
        memory = home.root.appendingPathComponent("optchat/memory.sqlite3")
        move = { session in
            guard let summary = try? await page.summary(session) else { return nil }
            return HomeAgentSessionReader.move(in: summary)
        }
    }

    /// - Parameters:
    ///   - memory: The Chief home's memory database.
    ///   - move: The acpmux summary's move by session id (tests pass a fake).
    init(memory: URL, move: @escaping @Sendable (String) async -> HomeAgentSessionMove?) {
        self.memory = memory
        self.move = move
    }

    /// Where agents `peers` run now; an agent with no session in the spawn records is left out.
    func read(_ peers: [String]) async -> [HomeAgentSessionRef] {
        []
    }

    /// The agents of the spawn records' JSON (`host/spawns`: spawn id to `{subs: [{id, session_id, place,
    /// epoch}]}`) that have a session.
    static func refs(spawns: Data) -> [HomeAgentSessionRef] {
        []
    }

    /// The `host/spawns` value of the memory database at `memory`, read-only; nil when it has none.
    static func spawnsValue(memory: URL) -> Data? {
        nil
    }

    /// The move an acpmux session summary records (`movedTo.host`, `moveEpoch`); nil when it never moved.
    static func move(in summary: [String: Any]) -> HomeAgentSessionMove? {
        nil
    }
}
