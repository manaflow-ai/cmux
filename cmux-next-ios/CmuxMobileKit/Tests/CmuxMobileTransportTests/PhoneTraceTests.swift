import Foundation
import Testing
@testable import CmuxMobileTransport

/// The phone's spans are acpmux's Chrome trace format (cmux#55505): complete events in a JSON
/// array Perfetto opens without its closing `]`, one W3C trace id per user action on the action
/// and on each round trip it makes.
struct PhoneTraceTests {
    private func events(_ path: String) throws -> [[String: Any]] {
        var text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("[\n"))
        // What Perfetto does: the array may end mid-way, with a trailing comma.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(",") { text.removeLast() }
        let array = try JSONSerialization.jsonObject(with: Data((text + "]").utf8))
        return try #require(array as? [[String: Any]])
    }

    @Test func anActionAndItsRoundTripsShareOneTraceID() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("phone-trace-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recorder = try #require(PhoneTrace.Recorder(path: path))
        var seen: String?
        try await PhoneTrace.action("close-tab", floorRoundTrips: 1, args: ["tab": "s10"], recorder: recorder) {
            seen = PhoneTrace.traceID
            #expect(PhoneTrace.meta?["traceId"] as? String == seen)
            PhoneTrace.roundTrip("close-tabs", start: PhoneTrace.Recorder.now())
            PhoneTrace.roundTrip("list-workspaces", start: PhoneTrace.Recorder.now())
        }
        let id = try #require(seen)
        #expect(id.count == 32 && id.allSatisfy(\.isHexDigit) && id != String(repeating: "0", count: 32))
        #expect(PhoneTrace.traceID == nil && PhoneTrace.meta == nil)

        let all = try events(path)
        #expect(all.map { $0["name"] as? String } == ["close-tabs", "list-workspaces", "close-tab"])
        #expect(all.map { $0["cat"] as? String } == ["daemon", "daemon", "action"])
        for event in all {
            #expect(event["ph"] as? String == "X")
            #expect((event["args"] as? [String: Any])?["trace_id"] as? String == id)
            #expect((event["ts"] as? Int64 ?? 0) > 1_700_000_000_000_000)
            #expect((event["dur"] as? Int64 ?? -1) >= 0)
        }
        let action = try #require(all.last?["args"] as? [String: Any])
        #expect(action["round_trips"] as? Int == 2)
        #expect(action["floor_round_trips"] as? Int == 1)
        #expect(action["tab"] as? String == "s10")
    }

    @Test func aRoundTripOutsideAnActionRecordsNothing() {
        PhoneTrace.roundTrip("list-workspaces", start: PhoneTrace.Recorder.now())
        #expect(PhoneTrace.traceID == nil)
    }
}
