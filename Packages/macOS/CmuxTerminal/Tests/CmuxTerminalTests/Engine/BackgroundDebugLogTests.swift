import Foundation
import Testing

@testable import CmuxTerminal

@Suite("Background debug log")
struct BackgroundDebugLogTests {
    @Test func disabledByDefaultWritesNothing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bg-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("bg.log")

        let log = BackgroundDebugLog(
            environment: ["CMUX_DEBUG_BG_LOG": logURL.path],
            defaults: isolatedDefaults(),
            startUptime: 0
        )
        #expect(!log.isEnabled)
        log.log("ignored when disabled")
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test func enabledViaEnvAppendsSequencedLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bg-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("bg.log")

        let log = BackgroundDebugLog(
            environment: [
                "CMUX_DEBUG_BG": "1",
                "CMUX_DEBUG_BG_LOG": logURL.path,
            ],
            defaults: isolatedDefaults(),
            startUptime: 0
        )
        #expect(log.isEnabled)
        log.log("first")
        log.log("second")

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(contents.contains("seq=1"))
        #expect(contents.contains("seq=2"))
        #expect(contents.contains("cmux bg: first"))
        #expect(contents.contains("cmux bg: second"))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "cmux.tests.bg-log.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}
