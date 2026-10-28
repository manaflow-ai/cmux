import CmuxNextTestSupport
import Foundation
import Testing

/// PerfResultWriter: no writer without CMUX_PERF_RESULT_DIR (a bench run by hand or by CI is unchanged), a refused
/// run when the runner's context is missing or wrong, and one result-v1 line per record with the context merged in
/// (scripts/perf-lab/tests/test_swift_benches.py reads such a line back with perf_result.py).
struct PerfResultWriterTests {
    private static var context: [String: Any] {
        [
            "story": "swift-lane-item",
            "run": ["id": "r1", "started_at": "2026-10-27T12:00:00.000000Z"],
            "build": ["sha": String(repeating: "a", count: 40), "config": "release", "measure_version": 1],
            "host": ["fingerprint": String(repeating: "b", count: 64), "class": "m4pro-48g-0hz", "chip": "Apple M4 Pro",
                     "macos": "26.1", "macos_build": "25B78", "display_hz": NSNull()],
            "engine": "none",
            "session": "light",
            "features": [String: Any](),
            "features_hash": NSNull(),
            "safe_mode": NSNull(),
            "attachments": [Any](),
        ]
    }

    private static func directory(context: [String: Any]? = Self.context) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-result-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let context {
            try JSONSerialization.data(withJSONObject: context).write(to: directory.appendingPathComponent(PerfResultWriter.contextFileName))
        }
        return directory
    }

    private static func environment(_ directory: URL) -> [String: String] {
        [PerfResultWriter.directoryVariable: directory.path]
    }

    @Test func noDirectoryMeansNoWriter() throws {
        #expect(try PerfResultWriter(environment: [:]) == nil)
        #expect(try PerfResultWriter(environment: [PerfResultWriter.directoryVariable: ""]) == nil)
    }

    @Test func aDirectoryWithoutTheRunnersContextIsRefused() throws {
        let directory = try Self.directory(context: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: PerfResultWriter.Failure.self) { try PerfResultWriter(environment: Self.environment(directory)) }
    }

    @Test func aContextWithAMetricFieldIsRefused() throws {
        var context = Self.context
        context["metric"] = "swift.lane_item.record_ns"
        let directory = try Self.directory(context: context)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: PerfResultWriter.Failure.self) { try PerfResultWriter(environment: Self.environment(directory)) }
    }

    @Test func aRecordIsOneResultLineWithTheContextAndRawSamples() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try #require(try PerfResultWriter(environment: Self.environment(directory)))
        let file = try writer.record("swift.lane_item.record_ns", unit: .ns, samples: [3.5, 1.25, 2])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasSuffix("\n") && text.dropLast().allSatisfy { $0 != "\n" }, "one line")
        let line = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(line["schema"] as? String == PerfResultWriter.schema)
        #expect(line["story"] as? String == "swift-lane-item")
        #expect(line["metric"] as? String == "swift.lane_item.record_ns")
        #expect(line["unit"] as? String == "ns")
        #expect(line["better"] as? String == "lower")
        #expect(line["samples"] as? [Double] == [3.5, 1.25, 2], "run order, never sorted")
        #expect(line["target_ref"] is NSNull)
        #expect(Set(line.keys) == PerfResultWriter.contextKeys.union(["schema", "metric", "unit", "better", "samples", "target_ref"]))
    }

    @Test func integerSamplesAndEachRecordGetTheirOwnFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try #require(try PerfResultWriter(environment: Self.environment(directory)))
        let first = try writer.record("swift.key_router.tis_calls", unit: .count, samples: [UInt64(4), 0])
        let second = try writer.record("swift.key_router.tis_calls", unit: .count, samples: [1])
        #expect(first != second)
        let line = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])
        #expect(line["samples"] as? [Double] == [4, 0])
    }

    @Test func aBadRecordWritesNothing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try #require(try PerfResultWriter(environment: Self.environment(directory)))
        #expect(throws: PerfResultWriter.Failure.noSamples(metric: "swift.x")) { try writer.record("swift.x", unit: .ms, samples: [Double]()) }
        #expect(throws: PerfResultWriter.Failure.nonFiniteSample(metric: "swift.x")) { try writer.record("swift.x", unit: .ms, samples: [1, .nan]) }
        #expect(throws: PerfResultWriter.Failure.invalidMetricName(".x")) { try writer.record(".x", unit: .ms, samples: [1]) }
        #expect(throws: PerfResultWriter.Failure.invalidMetricName("x y")) { try writer.record("x y", unit: .ms, samples: [1]) }
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".ndjson") }
        #expect(written.isEmpty)
    }
}
