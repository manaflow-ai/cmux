import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// The daemon's location trail (cx-hnmbt.12): the app reports each step and reads the rows back.
extension DaemonHistoryClient {
    /// Records one step of the location trail (`history.trail.record`, origin user). The daemon runs
    /// the app's step rules (`steps`, quick passes, `jump`) on its own trail, at the app's `time`.
    func recordTrail(window: String, location: HistoryLocation, at time: Date, steps: HistoryStepScope,
                     jump: Bool) async throws {
        let place = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(HistoryTrailLocation(location)))
        var params: [String: JSONValue] = [
            "window": .string(window), "location": place, "at_ms": Self.decimal(time), "steps": .string(steps.rawValue),
        ]
        if jump { params["jump"] = .bool(true) }
        _ = try await relay.send(operation: "history.trail.record", params: params, idempotencyKey: Self.key())
    }

    /// The daemon's trail, oldest first (at most its 200 entries).
    func trail() async throws -> [(location: HistoryLocation, time: Date)] {
        let rows = try await list(kinds: [.location], text: "", range: .all, limit: 5_000)
        return rows.reversed().compactMap { row in row.trailLocation.map { ($0, row.time) } }
    }
}
