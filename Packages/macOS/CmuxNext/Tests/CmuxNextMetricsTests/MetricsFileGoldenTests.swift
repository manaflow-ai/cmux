@testable import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// The metrics file bytes Swift writes match the golden the Rust writer pins
/// (cmux-tui/crates/cmux-trace/tests/fixtures/metrics-file-golden.txt, `metrics_tests.rs` in cmux-trace;
/// p09-observability task 131): the daemon's file and the app's file have one layout, so the app folds the daemon's
/// file (task 062) with its own reader.
@Suite("Metrics file golden")
struct MetricsFileGoldenTests {
    /// The golden's catalog, in file order (cmux-trace `GOLDEN_CATALOG`).
    private static let catalog: [HistogramID] = [
        .daemonRequest(.topology), .daemonDispatchQueue, .smoothnessDroppedPercent(.motion), .daemonUnresponsive,
    ]

    /// The golden's samples by catalog position (cmux-trace `GOLDEN_SAMPLES`).
    private static let samples: [(Int, Int64)] = [
        (0, 0), (0, 3), (0, 1_500), (0, 70_000_000), (0, -5), (1, 250), (2, 0), (2, 42), (2, 150), (3, 2), (3, 9), (3, -1),
    ]

    /// The golden's profile (cmux-trace `golden_header`).
    private static let profile = MetricsProfile(
        appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0", hardwareClass: "Mac16,10",
        bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
        buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))

    /// The golden's bytes: `bytes N`, then `<offset> <32 hex digits>` for each 16-byte row that is not zero.
    private static func goldenBytes() throws -> [UInt8] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let url = root.appending(path: "cmux-tui/crates/cmux-trace/tests/fixtures/metrics-file-golden.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var bytes: [UInt8] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            try #require(fields.count == 2, "\(line)")
            if fields[0] == "bytes" {
                let count = try #require(Int(fields[1]))
                bytes = [UInt8](repeating: 0, count: count)
                continue
            }
            let offset = try #require(Int(fields[0]))
            let hex = Array(fields[1].utf8)
            for index in 0 ..< hex.count / 2 {
                let pair = String(decoding: hex[index * 2 ..< index * 2 + 2], as: UTF8.self)
                bytes[offset + index] = try #require(UInt8(pair, radix: 16))
            }
        }
        return bytes
    }

    @Test("The file Swift writes is the Rust writer's golden, byte for byte")
    func fileMatchesTheRustGolden() throws {
        let golden = try Self.goldenBytes()
        let runtime = TraceRuntime(role: .daemon)
        let store = MetricsStore(role: .daemon, profile: Self.profile, pid: 4242, catalog: Self.catalog)
        #expect(store.attach(to: runtime))
        let metrics = Metrics(runtime: runtime)
        for (position, sample) in Self.samples { metrics.record(Self.catalog[position], sample) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "metrics-golden-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = try #require(store.adoptFile(directory: directory))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var written = [UInt8](data)
        try #require(written.count == golden.count, "file size")
        // The start clocks (offsets 32 to 47) are the process's own; the golden fixes them.
        written.replaceSubrange(32 ..< 48, with: golden[32 ..< 48])
        for offset in stride(from: 0, to: golden.count, by: 16) where written[offset ..< offset + 16] != golden[offset ..< offset + 16] {
            Issue.record("row \(offset) differs from the Rust golden")
        }
    }
}
