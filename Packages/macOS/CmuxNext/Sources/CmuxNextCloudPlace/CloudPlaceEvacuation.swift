import Foundation

/// An Evacuate (to Cloud) or Bring Back All (to this Mac) run as the chat header's `evacuate` shows it. The plan (which chats,
/// how many at once) is Rust's; this only keeps each chat's place in the run, and reads each running chat's step from its move's view.
public struct Evacuation: Equatable {
    public enum Phase: Equatable { case queued, running, ended, dropped }
    public struct Row: Equatable {
        public var session: String, title: String, phase: Phase
    }

    /// `toCloud` or `toLocal`.
    public var direction: String
    public var startedMs: UInt64
    /// When the last chat ended (or the run was cancelled and what ran had ended); nil while it runs.
    public var endedMs: UInt64?
    public var rows: [Row]
    /// Cancel was pressed: no queued chat starts.
    public var stopped = false
}

extension CloudPlaceFlows {
    /// A run of `chats` (session, title) starts: all queued.
    public func beginEvacuation(direction: String, chats: [(session: String, title: String)]) {
        evacuation = Evacuation(direction: direction, startedMs: nowMs, rows: chats.map { .init(session: $0.session, title: $0.title, phase: .queued) })
    }

    /// Whether the run still launches queued chats.
    public var evacuationStopped: Bool { evacuation?.stopped ?? true }

    /// The chat's move starts (`running`) or ends (`ended`); the run ends with its last chat.
    public func evacuationPhase(_ session: String, _ phase: Evacuation.Phase) {
        guard var run = evacuation, let index = run.rows.firstIndex(where: { $0.session == session }) else { return }
        run.rows[index].phase = phase
        if !run.rows.contains(where: { $0.phase == .queued || $0.phase == .running }) { run.endedMs = run.endedMs ?? nowMs }
        evacuation = run
    }

    /// Cancel: the queued chats are dropped and none starts; returns the sessions running now, whose moves the caller cancels.
    public func stopEvacuation() -> [String] {
        guard var run = evacuation, run.endedMs == nil else { return [] }
        run.stopped = true
        for index in run.rows.indices where run.rows[index].phase == .queued { run.rows[index].phase = .dropped }
        if !run.rows.contains(where: { $0.phase == .running }) { run.endedMs = nowMs }
        evacuation = run
        return run.rows.filter { $0.phase == .running }.map(\.session)
    }

    /// Chats Evacuate or Auto put on Cloud and not back yet, among `cloudSessions`.
    public func canBringBack(among cloudSessions: [String]) -> [String] { cloudSessions.filter { evacuated.contains($0) || autoMoved.contains($0) } }

    /// `evacuate` for pane.tabState: `{direction, chats: [{session, title, state, step?, reason?}], startedMs, elapsedMs, canBringBack}`;
    /// `canBringBack` alone when no run exists and it is more than 0; nil with neither.
    public func evacuateJSON(canBringBack count: Int) -> Data? {
        var object: [String: Any] = [:]
        if count > 0 { object["canBringBack"] = count }
        if let run = evacuation {
            let now = nowMs
            object["direction"] = run.direction
            object["startedMs"] = run.startedMs
            object["elapsedMs"] = (run.endedMs ?? now) &- run.startedMs
            object["canBringBack"] = count
            object["chats"] = run.rows.map { row -> [String: Any] in
                var chat: [String: Any] = ["session": row.session, "title": row.title]
                let view = views[row.session].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                switch row.phase {
                case .queued: chat["state"] = "queued"
                case .dropped: chat["state"] = "cancelled"
                case .running:
                    chat["state"] = "moving"
                    if let step = view?["step"] as? String { chat["step"] = step }
                case .ended:
                    // A move that left no flow (an FFI without the place ops) is read as failed, never as landed.
                    let state = (view?["state"] as? String).flatMap { ["live", "failed", "cancelled"].contains($0) ? $0 : nil }
                    chat["state"] = state ?? "failed"
                    if let step = view?["step"] as? String { chat["step"] = step }
                    if let reason = view?["reason"] as? String { chat["reason"] = reason }
                }
                return chat
            }
        }
        return object.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
