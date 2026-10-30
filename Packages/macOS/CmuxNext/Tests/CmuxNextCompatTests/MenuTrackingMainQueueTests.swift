import Foundation
import Testing

/// Why host context menus pop up from a main run-loop block (``MainRunLoopBlock``), never inside a
/// main-queue job: runs scripts/measure/menu-tracking-main-queue.swift (a real NSApplication run
/// loop, which a test inside swift-testing's own main-queue job cannot drive) and checks that work
/// queued while a menu tracks waits for the menu only when the menu opened inside a job. The
/// closing click waited on that backlog (Leo, 2026-10-29: "clicking out of a fucking context menu
/// is sometimes slow as fucking balls").
@Suite struct MenuTrackingMainQueueTests {
    static let program = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/measure/menu-tracking-main-queue.swift")

    /// Each MENU-TRACKING line's numbers by key.
    static func lines(_ output: String) -> [String: [String: Double]] {
        var rows: [String: [String: Double]] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("MENU-TRACKING ") {
            let words = line.split(separator: " ")
            var values: [String: Double] = [:]
            for word in words.dropFirst(2) {
                let pair = word.split(separator: "=")
                if pair.count == 2, let value = Double(pair[1]) { values[String(pair[0])] = value }
            }
            rows[String(words[1])] = values
        }
        return rows
    }

    @Test func workQueuedWhileAMenuTracksWaitsOnlyWhenTheMenuOpenedInsideAJob() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "menu-tracking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appending(path: "bench")
        let compile = Process()
        compile.executableURL = URL(filePath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-O", "-o", binary.path, Self.program.path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0, "the measurement did not compile")
        let run = Process()
        run.executableURL = binary
        run.arguments = ["0.3", "5"]
        let pipe = Pipe()
        run.standardOutput = pipe
        try run.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        print(output)
        let rows = Self.lines(output)
        let inJob = try #require(rows["in-main-queue-job"]), fromCallout = try #require(rows["run-loop-callout"])
        // Inside a job the queued work waits for most of the 300 ms menu; from a callout it runs as it comes.
        #expect(inJob["worst_wait_ms", default: 0] > 150)
        #expect(fromCallout["worst_wait_ms", default: .infinity] < 50)
        #expect(fromCallout["drain_after_close_ms", default: .infinity] < 20)
    }
}
