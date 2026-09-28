import CmuxAgentChat
import Foundation

/// Folds admitted agent hooks into per-pane, per-session turn facts for `agent.list`.
///
/// `agent.hook.enqueue` records every event here before queue admission, so a
/// best-effort tool event the delivery queue later coalesces still counts.
/// Recording parses at most one bounded payload and takes one short lock.
final class AgentHookActivityTracker: @unchecked Sendable {
    static let shared = AgentHookActivityTracker()

    /// Sessions kept across all panes; the least recently updated are dropped first.
    static let maximumSessions = 512

    private struct Key: Hashable {
        var surfaceID: UUID
        var sessionID: String
    }

    private let lock = NSLock()
    private var states: [Key: AgentHookActivityState] = [:]

    init() {}

    /// Records one hook event. Events without a pane or session id are ignored.
    func record(_ event: AgentHookDeliveryEvent, at date: Date = Date()) {
        guard let rawSurfaceID = event.environment["CMUX_SURFACE_ID"],
              let surfaceID = UUID(uuidString: rawSurfaceID),
              let parsed = AgentHookActivityState.Event.parse(
                  subcommand: event.subcommand,
                  payload: Data(event.payload.utf8),
                  relayBacked: event.relayBacked
              ),
              let sessionID = parsed.sessionID ?? event.sessionID else {
            return
        }
        record(parsed.event, surfaceID: surfaceID, sessionID: sessionID, at: date)
    }

    func record(_ event: AgentHookActivityState.Event, surfaceID: UUID, sessionID: String, at date: Date) {
        let key = Key(surfaceID: surfaceID, sessionID: sessionID)
        lock.lock()
        defer { lock.unlock() }
        var state = states[key] ?? AgentHookActivityState()
        state.apply(event, at: date)
        states[key] = state
        if states.count > Self.maximumSessions {
            let overflow = states.count - Self.maximumSessions
            let oldest = states.sorted { ($0.value.since ?? .distantPast) < ($1.value.since ?? .distantPast) }
                .prefix(overflow)
                .map(\.key)
            for key in oldest { states.removeValue(forKey: key) }
        }
    }

    /// The facts for one session in one pane. `sessionIDs` lists every id the
    /// registry knows the session by; the first recorded one wins.
    func state(surfaceID: UUID, sessionIDs: [String]) -> AgentHookActivityState? {
        lock.lock()
        defer { lock.unlock() }
        for sessionID in sessionIDs {
            if let state = states[Key(surfaceID: surfaceID, sessionID: sessionID)] { return state }
        }
        return nil
    }
}
