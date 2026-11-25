import CmuxNextCompat
@testable import CmuxNextUpdater
import CmuxNextWakeups
import Foundation
import Testing

/// The updater's trace on disk (ask-8112d98df7, 2026-11-04): unified logging kept none of a
/// nightly's updater lines on Leo's Mac, so what relaunched cmux after a Download click could not
/// be traced. Every line reaches `~/Library/Logs/cmux-next/<bundle>-updater.log`, in order.
@Suite(.timeLimit(.minutes(1))) struct UpdateLogFileTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "update-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func everyLineReachesTheFileInOrderWithItsTimeAndProcess() async throws {
        let directory = try scratch()
        defer { try? FileManager.checked.removeItem(at: directory) }
        let work = BackgroundWork(label: "test.update-log")
        let url = directory.appending(path: "logs/com.cmuxterm.app.nightly-updater.log")
        let log = UpdateLogBuffer(file: UpdateLogFile(url: url, work: work))
        for index in 0..<50 { log.append("line \(index)") }
        // Quit waits for the lines (block-shutdown): the ones just before an install's quit count most.
        await work.shutdown()
        let text = try String(blockingContentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 50)
        #expect(lines.map { $0.components(separatedBy: "] ").last ?? "" } == (0..<50).map { "line \($0)" })
        #expect(lines.allSatisfy { $0.contains("[\(ProcessInfo.processInfo.processIdentifier)] ") })
        #expect(log.logPath() == url.path, "error details point at the file, not a log show command")
    }

    @Test func aFullFileMovesAsideBeforeTheNextLine() async throws {
        let directory = try scratch()
        defer { try? FileManager.checked.removeItem(at: directory) }
        let url = directory.appending(path: "updater.log")
        try Data(repeating: UInt8(ascii: "x"), count: Int(UpdateLogFile.rotateBytes)).blockingWrite(to: url)
        let work = BackgroundWork(label: "test.update-log-rotate")
        UpdateLogFile(url: url, work: work).write("after rotation")
        await work.shutdown()
        #expect(try String(blockingContentsOf: url, encoding: .utf8).hasSuffix("after rotation\n"))
        let old = try FileManager.checked.attributesOfItem(atPath: url.appendingPathExtension("1").path)[.size] as? UInt64
        #expect(old == UpdateLogFile.rotateBytes)
    }

    @Test func aTestProcessWritesNoLogFile() {
        #expect(UpdateLogFile.isTestProcess(name: "swiftpm-testing-helper", environment: [:]))
        #expect(UpdateLogFile.isTestProcess(name: "cmux", environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(!UpdateLogFile.isTestProcess(name: "cmux", environment: [:]))
        #expect(UpdateLogFile.app(bundleIdentifier: "com.cmuxterm.app.nightly", work: BackgroundWork(label: "test.update-log-app")) == nil)
    }
}
