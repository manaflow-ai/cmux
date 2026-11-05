#if DEBUG
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The always-on flicker detector's ring file (Leo, 2026-11-04: "a flicker across nearly the full
/// screen"): each line carries its time in UTC, a page's events keep only known kinds and short
/// scalar fields, and the file rolls over to `.1` past its size, so it never grows without bound.
@Suite
struct AgentPageFlickerLogTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "flicker-log-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func aLineCarriesItsTimeInUTC() throws {
        let log = AgentPageFlickerLog(directory: directory())
        defer { try? FileManager.default.removeItem(at: log.directory) }
        log.record("navigation", at: Date(timeIntervalSince1970: 1_793_836_520.25), ["page": "chat:s1"])
        log.flush()
        let line = try #require(try lines(log.url).first)
        #expect(line["kind"] as? String == "navigation")
        #expect(line["at"] as? String == "2026-11-04T23:55:20.250Z")
        #expect(line["page"] as? String == "chat:s1")
    }

    @Test func aPageKeepsOnlyKnownKindsAndShortFields() throws {
        let params: [String: Any] = ["events": [
            ["kind": "long-frame", "at": 1_793_836_520_250.0, "ms": 167.04],
            ["kind": "visibility", "at": 1_793_836_521_000.0, "state": "hidden", "text": String(repeating: "x", count: 200)],
            ["kind": "anything-else", "at": 0],
            ["kind": "transcript-mount", "n": 2, "nested": ["a": 1]],
        ]]
        let decoded = try AgentPageFlickerLog.pageLines(params, page: "chat:s1", pid: 42).map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        #expect(decoded.map { $0["kind"] as? String } == ["long-frame", "visibility", "transcript-mount"])
        #expect(decoded[0]["ms"] as? Double == 167)
        #expect(decoded[0]["at"] as? String == "2026-11-04T23:55:20.250Z")
        #expect(decoded[0]["pid"] as? Int == 42 && decoded[0]["page"] as? String == "chat:s1")
        #expect(decoded[1]["state"] as? String == "hidden" && decoded[1]["text"] == nil)
        #expect(decoded[2]["n"] as? Double == 2 && decoded[2]["nested"] == nil)
    }

    @Test func theFileRollsOverPastItsSize() throws {
        let log = AgentPageFlickerLog(directory: directory())
        defer { try? FileManager.default.removeItem(at: log.directory) }
        let filler = String(repeating: "f", count: 1000)
        for _ in 0...(AgentPageFlickerLog.maximumBytes / 1000) { log.record("long-frame", ["note": filler]) }
        log.record("visibility", ["state": "visible"])
        log.flush()
        let older = log.directory.appending(path: AgentPageFlickerLog.olderName)
        #expect(FileManager.default.fileExists(atPath: older.path))
        let current = try lines(log.url)
        #expect(current.last?["kind"] as? String == "visibility")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? Int)
        #expect(size < AgentPageFlickerLog.maximumBytes)
        let olderSize = try #require(try FileManager.default.attributesOfItem(atPath: older.path)[.size] as? Int)
        #expect(olderSize <= AgentPageFlickerLog.maximumBytes)
    }
}
#endif
