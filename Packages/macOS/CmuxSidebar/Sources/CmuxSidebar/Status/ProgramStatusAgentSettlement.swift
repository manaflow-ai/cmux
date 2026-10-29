/// Decides when an agent's own OSC 7501 report proves its turn ended.
///
/// Agent hooks write the sidebar's "Running" row, and a turn that ends without
/// its Stop hook leaves that row stuck: Claude Code runs no Stop hook when the
/// user interrupts a turn with Esc, and a Stop hook that times out or fails is
/// never delivered. Claude Code also reports its own activity as an OSC 7501
/// `working` record. When that record leaves the working and blocked states,
/// the agent itself says the turn is over, so a pane still marked running can
/// settle without guessing from timers or output.
public struct ProgramStatusAgentSettlement: Sendable {
    /// OSC 7501 `app` names that map to an agent status key.
    private static let statusKeysByApp: [String: String] = [
        "claude-code": "claude_code",
    ]

    public init() {}

    /// The agent status key an OSC 7501 app reports for, if any.
    public func statusKey(forApp app: String?) -> String? {
        guard let app else { return nil }
        return Self.statusKeysByApp[app.lowercased()]
    }

    /// Agent status keys whose app had a working or blocked record before a
    /// change and has none after it.
    ///
    /// - Parameters:
    ///   - previous: The panel's records before the change.
    ///   - current: The panel's records after the change.
    /// - Returns: The keys whose agent reported the end of its activity.
    public func endedActivityStatusKeys(
        previous: ProgramStatusRecordStore,
        current: ProgramStatusRecordStore
    ) -> Set<String> {
        activeStatusKeys(in: previous).subtracting(activeStatusKeys(in: current))
    }

    /// Whether the panel still has a working or blocked record for the key.
    public func isActive(statusKey: String, in store: ProgramStatusRecordStore) -> Bool {
        activeStatusKeys(in: store).contains(statusKey)
    }

    private func activeStatusKeys(in store: ProgramStatusRecordStore) -> Set<String> {
        var keys = Set<String>()
        for record in store.records where record.state == .working || record.state == .blocked {
            if let key = statusKey(forApp: store.effectiveApp(for: record)) {
                keys.insert(key)
            }
        }
        return keys
    }
}
