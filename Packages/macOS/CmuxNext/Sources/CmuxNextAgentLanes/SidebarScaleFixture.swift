#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// `debug.scale_fixture` (DEBUG and bench builds): the Chief half of the scale fixture
/// (scripts/cmux-next/scale-fixture-bench.py: 1,100 workspaces, 5 Chiefs, a 160 KB cmux.json). The bench
/// opens one workspace per session with the app's own `agent.openSessionWorkspace`; this makes each
/// of those sessions a Chief's subagent on this Mac, so every one of those sidebar rows asks for its
/// Chief's avatar on every row flush (`SidebarLaneStatus`), as the rows of a person with that many
/// Chief-run chats do (the 2026-11-26 beach ball, cmux#59531).
///
/// JSON params: `chiefs` (default 5, at most 20), `sessions` [session id] (the workspaces' chats),
/// `tick` (flips that many fixture chats between working and idle: the rows map again, a flush as an
/// agent's step makes), `clear` (removes them). Answers `chiefs`, `lanes`, the `owned` workspaces
/// (a chat tab whose session one of these Chiefs owns, read as `SidebarLaneStatus` reads it),
/// `workspaces` and `local_host`, so the bench knows its rows ask for avatars before it times them.
@MainActor
public enum SidebarScaleFixture {
    static let prefix = "scale-fixture-", childrenPrefix = "scale-fixture-kids-"

    private struct Params: Decodable { var chiefs: Int?, sessions: [String]?, tick: Int?, clear: Bool? }

    public static func handle(json: Data, localHost: String?, workspaces: [WorkspaceModel],
                              lanes store: AgentLaneStore = .shared, turns: AgentTurnStateStore = .shared) -> [String: Any] {
        // main-actor-ok: a DEBUG bench fixture's params, once per bench step.
        let params = (try? JSONDecoder().decode(Params.self, from: json)) ?? Params()
        // The sidebar takes a chat as this Mac's when its host is the turn store's local host (set
        // when the lane watch starts; a bench launch may run none).
        if turns.localHost == nil { turns.localHost = localHost }
        var lanes = store.lanes
        if params.clear == true {
            store.lanes = lanes.filter { !$0.key.hasPrefix(prefix) && $0.value.parent?.hasPrefix(childrenPrefix) != true }
        } else if let ticks = params.tick {
            // fleet-only-ok: whole file is #if DEBUG || CMUX_BENCH_HOOKS; runs only when the scale bench calls debug.scale_fixture
            let fixture = lanes.compactMap { $0.value.parent?.hasPrefix(childrenPrefix) == true ? $0.key : nil }
            for id in fixture.shuffled().prefix(max(0, ticks)) {
                guard let lane = lanes[id] else { continue }
                lanes[id] = AgentActivityLane(id: id, name: lane.name, title: lane.title, peer: nil, parent: lane.parent,
                                              state: lane.state == .working ? .idle : .working, since: Date(), error: nil,
                                              harness: lane.harness)
            }
            store.lanes = lanes
        } else {
            let count = min(20, max(1, params.chiefs ?? 5)), sessions = params.sessions ?? [], named = Set(sessions)
            lanes = lanes.filter { !$0.key.hasPrefix(prefix) && !named.contains($0.key) }
            let now = Date()
            for index in 0..<count {
                let id = prefix + "chief-\(index)"
                lanes[id] = AgentActivityLane(id: id, name: "scale-chief-\(index)", title: "Scale Chief \(index)", peer: nil, parent: nil,
                                              state: .idle, since: now, error: nil, harness: "claude",
                                              chiefChildren: childrenPrefix + "\(index)", chiefParticipant: chief(index))
            }
            for (index, session) in sessions.enumerated() {
                // The workspace's chat is the bench's session id; the lane is keyed by it, as acpmux's watch keys a lane.
                lanes[session] = AgentActivityLane(id: session, name: "scale-\(index)", title: "Scale chat \(index)", peer: nil,
                                                   parent: childrenPrefix + "\(index % count)",
                                                   state: index.isMultiple(of: 3) ? .working : .idle, since: now, error: nil, harness: "claude")
            }
            store.lanes = lanes
        }
        return report(workspaces: workspaces, store: store, localHost: turns.localHost)
    }

    /// The participant id of fixture Chief `index` (`agent_scale00`…); the bench names their mascots.
    public static func chief(_ index: Int) -> String { "agent_scale" + String(format: "%02d", index) }

    private static func report(workspaces: [WorkspaceModel], store: AgentLaneStore, localHost: String?) -> [String: Any] {
        let owned = workspaces.filter { workspace in
            workspace.screens.flatMap(\.panes).flatMap(\.tabs).contains { tab in
                guard let ref = tab.agentSession, let id = ref.session, ref.host == localHost || ref.host.hasPrefix("chief:"),
                      let lane = store.lane(id), lane.peer == nil, let parent = lane.parent else { return false }
                return store.chiefParticipants[parent] != nil
            }
        }.count
        return [
            "chiefs": store.chiefParticipants.keys.filter { $0.hasPrefix(childrenPrefix) }.count,
            "lanes": store.lanes.values.filter { $0.parent?.hasPrefix(childrenPrefix) == true }.count,
            "owned": owned, "workspaces": workspaces.count, "local_host": localHost ?? NSNull(),
        ]
    }
}
#endif
