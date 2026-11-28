import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive
@testable import CmuxMobileTransport

/// Close Tab before and after, in one harness: the same mock Mac answers every write after a
/// fixed link round trip, and PhoneTrace times the action (Chrome trace JSON in
/// `CMUX_TRACE_FILE`, or a temp file). Before: the old close-surface + close-terminal + tree
/// reload the phone waited for; after: one `close-tabs`. 40 ms is a phone on Wi-Fi to a Mac
/// over the tailnet; 300 ms (duress) is a phone on a weak cell link through TURN.
@MainActor
@Suite struct CloseTabRoundTripBench {
    struct Run { var name: String; var roundTrips: Int; var millis: Double }

    func close(legacy: Bool, roundTrip: TimeInterval, recorder: PhoneTrace.Recorder) async throws -> Run {
        let seen = TabCloseEndsTerminalTests.Requests()
        let harness = TabCloseEndsTerminalTests()
        let (backend, sync) = try await harness.connected(seen, roundTrip: roundTrip)
        let (tab, workspace) = try harness.tab("s10", in: sync)
        // bind ends by starting one more list in a Task it does not await. The legacy close's
        // listNow joins a list still in flight, and that list's request is then counted on
        // bind's task, not this action's (base runs 45820613178, 45826673120: 2 round trips).
        // Join or start it here, so the action times only its own requests.
        await sync.refresh()
        let name = "close-tab \(legacy ? "before" : "after") rtt=\(Int(roundTrip * 1000))ms"
        let start = Date()
        try await PhoneTrace.action(name, floorRoundTrips: 1, args: [:], recorder: recorder) {
            if legacy {
                let client = try #require(sync.daemon)
                try await backend.legacyClose(surface: 10, terminals: [.init(id: "term_a", incarnation: "inc_a")], on: client)
            } else {
                try await backend.closeTab(tab, in: workspace)
            }
        }
        let millis = Date().timeIntervalSince(start) * 1000
        return Run(name: name, roundTrips: try roundTrips(of: name, in: recorder.path), millis: millis)
    }

    /// The `round_trips` the trace file says the action `name` took.
    func roundTrips(of name: String, in path: String) throws -> Int {
        var text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(",") { text.removeLast() }
        let events = try #require(try JSONSerialization.jsonObject(with: Data((text + "]").utf8)) as? [[String: Any]])
        let action = try #require(events.last { $0["name"] as? String == name })
        return try #require((action["args"] as? [String: Any])?["round_trips"] as? Int)
    }

    @Test func closeTabBeforeAndAfter() async throws {
        let path = ProcessInfo.processInfo.environment["CMUX_TRACE_FILE"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("close-tab-\(UUID().uuidString).json").path
        let recorder = try #require(PhoneTrace.Recorder(path: path))
        var runs: [Run] = []
        for roundTrip in [0.040, 0.300] {
            let before = try await close(legacy: true, roundTrip: roundTrip, recorder: recorder)
            let after = try await close(legacy: false, roundTrip: roundTrip, recorder: recorder)
            #expect(after.roundTrips == 1)
            #expect(before.roundTrips >= 3)
            #expect(after.millis < before.millis)
            runs += [before, after]
        }
        for run in runs {
            print("close-tab-bench \(run.name): \(run.roundTrips) round trips, \(String(format: "%.0f", run.millis)) ms")
        }
        print("close-tab-bench trace: \(path)")
    }
}
