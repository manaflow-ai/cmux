#if DEBUG
@testable import CMUXDebugLog
import XCTest

final class DebugEventLogFileSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-debug-log-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLogDoesNotWriteThroughASymlinkAtTheLogPath() throws {
        let victim = directory.appendingPathComponent("victim.txt")
        try "original\n".write(to: victim, atomically: true, encoding: .utf8)
        let logPath = directory.appendingPathComponent("cmux-debug.log").path
        try FileManager.default.createSymbolicLink(atPath: logPath, withDestinationPath: victim.path)

        let log = DebugEventLog(logPath: logPath)
        log.log("focus.change surface=1")
        log.waitForPendingAppends()

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "original\n")
    }

    func testLogDoesNotAppendThroughAHardLinkAtTheLogPath() throws {
        let victim = directory.appendingPathComponent("victim.txt")
        try "original\n".write(to: victim, atomically: true, encoding: .utf8)
        let logPath = directory.appendingPathComponent("cmux-debug.log").path
        try FileManager.default.linkItem(atPath: victim.path, toPath: logPath)

        let log = DebugEventLog(logPath: logPath)
        log.log("focus.change surface=1")
        log.waitForPendingAppends()

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "original\n")
    }

    func testLogCreatesAFileOnlyItsOwnerCanRead() throws {
        let logPath = directory.appendingPathComponent("cmux-debug.log").path

        let log = DebugEventLog(logPath: logPath)
        log.log("focus.change surface=1")
        log.waitForPendingAppends()

        let attributes = try FileManager.default.attributesOfItem(atPath: logPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
        XCTAssertTrue(try String(contentsOfFile: logPath, encoding: .utf8).contains("focus.change surface=1"))
    }
}
#endif
