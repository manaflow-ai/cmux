import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextIPC
import Foundation

/// The daemon's location trail (cx-hnmbt.12): the app reports each step and reads the rows back.
extension DaemonHistoryClient {
    /// Records one step of the location trail (`history.trail.record`, origin user). The daemon runs
    /// the app's step rules (`steps`, quick passes, `jump`) on its own trail, at the app's `time`.
    /// Answers the daemon's reply: the entry the step landed in and whether its trail changed.
    @discardableResult
    func recordTrail(window: String, location: HistoryLocation, at time: Date, steps: HistoryStepScope,
                     jump: Bool) async throws -> (id: String?, recorded: Bool?) {
        let reply = try await mutate(Self.trailRequest(window: window, location: location, at: time, steps: steps, jump: jump),
                                     value: V2HistoryTrailRecordResult.self)
        return (reply.id, reply.recorded)
    }

    /// The `history.trail.record` request: `jump` only when set. Building it copies the step's
    /// fields; the line is encoded on the connection's actor, so no codec runs between a pane
    /// focus move and its frame (a515).
    static func trailRequest(window: String, location: HistoryLocation, at time: Date, steps: HistoryStepScope,
                             jump: Bool) -> V2HistoryTrailRecordRequest {
        V2HistoryTrailRecordRequest(atMs: milliseconds(time), jump: jump ? true : nil, location: wireLocation(location),
                                    steps: V2HistoryTrailRecordRequest.Steps(rawValue: steps.rawValue), window: window)
    }

    /// `location` as the catalog's `HistoryTrailLocation`, field for field ``HistoryTrailLocation``.
    static func wireLocation(_ location: HistoryLocation) -> V2HistoryTrailLocation {
        let place = HistoryTrailLocation(location)
        return V2HistoryTrailLocation(content: place.content, cwd: place.cwd, machine: place.machine,
                                      machineName: place.machineName, page: place.page, pane: place.pane,
                                      room: place.room, screen: place.screen, tab: place.tab, title: place.title,
                                      url: place.url, workspace: place.workspace, workspaceTitle: place.workspaceTitle)
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
