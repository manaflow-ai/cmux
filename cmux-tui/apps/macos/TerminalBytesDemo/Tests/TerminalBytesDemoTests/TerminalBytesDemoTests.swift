import XCTest
@testable import TerminalBytesDemo

final class TerminalBytesDemoTests: XCTestCase {
    func testDemoConfigurationUsesOnlyExplicitEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invitation = directory.appendingPathComponent("invitation.txt")
        try "cmux://enroll/fresh\n".write(to: invitation, atomically: true, encoding: .utf8)

        let configuration = DemoLaunchConfiguration.processEnvironment([
            "CMUX_TERMINAL_INVITATION_FILE": invitation.path,
            "CMUX_TERMINAL_SURFACE": "73",
            "CMUX_TERMINAL_AUTOCONNECT": "1",
        ])

        XCTAssertEqual(
            configuration,
            DemoLaunchConfiguration(
                invitation: "cmux://enroll/fresh",
                surface: "73",
                autoConnect: true
            )
        )
    }

    func testGeometryClampsToValidTerminalCells() {
        XCTAssertEqual(
            terminalGeometry(width: 0, height: 0),
            TerminalGeometry(cols: 1, rows: 1)
        )
        XCTAssertEqual(
            terminalGeometry(width: 840, height: 340),
            TerminalGeometry(cols: 100, rows: 20)
        )
    }

    func testCStringCopyRetriesWhenValueGrowsBetweenPasses() {
        var calls = 0
        let value = copyGrowingCString { buffer, capacity in
            calls += 1
            let bytes = Array((calls == 1 ? "old" : "new-日本語").utf8)
            if let buffer, capacity > 0 {
                let copied = min(bytes.count, capacity - 1)
                for index in 0..<copied {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[copied] = 0
            }
            return bytes.count
        }
        XCTAssertEqual(value, "new-日本語")
        XCTAssertGreaterThanOrEqual(calls, 3)
    }
}
