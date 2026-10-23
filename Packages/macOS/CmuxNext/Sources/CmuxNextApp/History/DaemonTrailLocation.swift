import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// The daemon's location trail (cx-hnmbt.12): the app reports each step and reads the rows back.
extension DaemonHistoryClient {
    /// Records one step of the location trail (`history.trail.record`, origin user). The daemon runs
    /// the app's step rules (`steps`, quick passes, `jump`) on its own trail, at the app's `time`.
    /// Answers the daemon's reply: the entry the step landed in and whether its trail changed.
    @discardableResult
    func recordTrail(window: String, location: HistoryLocation, at time: Date, steps: HistoryStepScope,
                     jump: Bool) async throws -> (id: String?, recorded: Bool?) {
        let place = try await Self.place(HistoryTrailLocation(location))
        var params: [String: JSONValue] = [
            "window": .string(window), "location": place, "at_ms": Self.decimal(time), "steps": .string(steps.rawValue),
        ]
        if jump { params["jump"] = .bool(true) }
        let result = try await relay.send(operation: "history.trail.record", params: params, idempotencyKey: Self.key())
        guard case .object(let reply) = result, case .object(let value)? = reply["value"] else { return (nil, nil) }
        let id: String? = if case .string(let id)? = value["id"] { id } else { nil }
        let recorded: Bool? = if case .bool(let recorded)? = value["recorded"] { recorded } else { nil }
        return (id, recorded)
    }

    /// The step's location as the relay's JSON, encoded on the global executor: every settled pane
    /// focus move reports a step, and the codec must not run between the move and its frame (a515).
    @concurrent static func place(_ location: HistoryTrailLocation) async throws -> JSONValue {
        if pthread_main_np() != 0 { await DebugSwitchWork.note("trail_encodes") }
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(location))
    }

    /// The daemon's trail, oldest first (at most its 200 entries): every step of its trail document,
    /// also the ones History does not list (``HistoryTrailDocument``). Before the daemon's first write
    /// there is no document; the rows then show the app's older trail, adopted.
    func trail() async throws -> [(location: HistoryLocation, time: Date)] {
        let stored = try await connection.frontendProjection(subject: HistoryTrailDocument.subject)
        if stored.projection != .null, stored.schemaVersion == HistoryTrailDocument.schemaVersion,
           let document = try? await Self.decode(HistoryTrailDocument.self, from: stored.projection) {
            return document.steps
        }
        let rows = try await list(kinds: [.location], text: "", range: .all, limit: 5_000)
        return rows.reversed().compactMap { row in row.trailLocation.map { ($0, row.time) } }
    }
}
