import CmuxNextAgentActivity
import CmuxNextDaemon

/// The short id (`a612`) a Chief knows each subagent's workspace by, so Cmd-P finds the
/// workspace when the person types the id the Chief gave them (Lawrence 2026-10-23, msg 11943).
///
/// The Chief stores the id with the subagent's acpmux session: it names the session
/// `optchat-sub-<home id>-a<N>` (optchat-chief `subagents.rs`) and opens the workspace with that
/// session's chat tab, so the chat tab links the workspace to its id, for workspaces made before
/// this lookup existed as well. An older Chief also put the id in front of the workspace name
/// (`a345 · task`), which still names it when its session is gone.
@MainActor
struct ChiefSubagentIDs {
    /// The acpmux lane of a session id, from the Chief's watch or this Mac's.
    private let lane: @MainActor (String) -> AgentActivityLane?

    init(lane: @escaping @MainActor (String) -> AgentActivityLane?) {
        self.lane = lane
    }

    /// Fixed lanes, keyed by session id (tests).
    init(lanes: [String: AgentActivityLane]) {
        self.init { lanes[$0] }
    }

    /// The app's watches: the Chief home's acpmux, where Chiefs run their subagents, then this Mac's.
    static var live: ChiefSubagentIDs {
        ChiefSubagentIDs { AgentLaneStore.chief.lane($0) ?? AgentLaneStore.shared.lane($0) }
    }

    /// The subagent id of the workspace named `name` whose agent chat tabs show `chats`, else nil.
    func id(name: String, chats: [AgentSessionRef]) -> String? {
        for chat in chats {
            if let session = chat.session, let lane = lane(session), let id = Self.id(sessionName: lane.name) { return id }
        }
        return Self.id(workspaceName: name)
    }

    /// The `a<N>` of a Chief subagent's session name (`optchat-sub-<home id>-a<N>`, `-<m>` after it
    /// when acpmux deduped the name, `<peer>/` before it for a peer's session), else nil.
    static func id(sessionName: String) -> String? {
        let bare = sessionName.split(separator: "/").last.map(String.init) ?? sessionName
        let parts = bare.split(separator: "-")
        guard parts.count > 3, parts[0] == "optchat", parts[1] == "sub" else { return nil }
        return handle(parts[3])
    }

    /// The `a<N>` an older Chief put in front of a subagent's workspace name (`a345 · task`), else nil.
    static func id(workspaceName: String) -> String? {
        let name = workspaceName.drop(while: \.isWhitespace)
        guard let dot = name.range(of: " · ") else { return nil }
        return handle(name[..<dot.lowerBound])
    }

    /// `text` when it is `a` and digits.
    private static func handle(_ text: Substring) -> String? {
        guard text.count > 1, text.first == "a", text.dropFirst().allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return String(text)
    }
}
