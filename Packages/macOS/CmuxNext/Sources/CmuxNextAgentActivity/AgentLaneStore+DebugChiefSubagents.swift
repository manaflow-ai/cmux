#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

extension AgentLaneStore {
    /// DEBUG ONLY: one fixture Chief subagent (`debug.chief.subagent_fixture`).
    private struct DebugChiefSubagent: Decodable {
        var title: String?
        var state: String?
        var done: Int?
        var total: Int?
        var current: String?
        var next: String?
        var harness: String?
    }

    private struct DebugChiefSubagents: Decodable { var subagents: [DebugChiefSubagent] }

    private static let debugChiefSubagentPrefix = "debug-chief-sub-"

    /// DEBUG ONLY. `debug.chief.subagent_fixture` {subagents: [{title, state?, done?, total?, current?, next?, harness?}]}:
    /// puts that many fixture subagents in this store (the Chief's, ``chief``), which draw as the indented rows under
    /// the sidebar's top Chief row, so a capture shows them with no Chief subagent running on the Mac.
    ///
    /// `state` is working (the default), input, idle, failed or lost; `total` (with `done`, `current` and `next`)
    /// gives the subagent a task list (``AgentActivityLane/taskList``). `subagents: []` removes them. Only the
    /// fixture's own lanes change; the real ones stay as the watch wrote them.
    /// - Parameter json: the command's params, encoded.
    /// - Returns: the number of fixture subagents now in the store.
    /// - Throws: a `DecodingError` when `json` has no `subagents` list.
    @discardableResult
    public func applyDebugChiefSubagents(json: Data) throws -> Int {
        // main-actor-ok: a DEBUG fixture command's params, a few fixture rows a capture asks for.
        let entries = try JSONDecoder().decode(DebugChiefSubagents.self, from: json).subagents
        var next = lanes.filter { !$0.key.hasPrefix(Self.debugChiefSubagentPrefix) }
        for (index, entry) in entries.enumerated() {
            let number = index + 1
            let id = Self.debugChiefSubagentPrefix + String(number)
            let list = entry.total.map { total in
                AgentTaskList(source: .harness, done: entry.done ?? 0, total: total, current: entry.current,
                              next: entry.next, updatedAt: Date())
            }
            next[id] = AgentActivityLane(id: id, name: "optchat-sub-debug000-a\(number)",
                                         title: entry.title ?? "Subagent \(number)", peer: nil,
                                         parent: "optchat-chief:debug000",
                                         state: entry.state.flatMap(AgentActivityLane.State.init(rawValue:)) ?? .working,
                                         since: Date(), error: nil, harness: entry.harness ?? "claude", taskList: list)
        }
        lanes = next
        return entries.count
    }
}
#endif
