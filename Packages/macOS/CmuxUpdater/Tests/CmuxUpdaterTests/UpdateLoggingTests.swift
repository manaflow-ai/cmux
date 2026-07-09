import Foundation
import Testing
@testable import CmuxUpdater

/// A trivial in-memory ``UpdateLogging`` used to exercise the protocol's default
/// ``UpdateLogging/clipboardPayload()`` formatting without touching the filesystem.
private final class StubUpdateLog: UpdateLogging, @unchecked Sendable {
    private let lines: String
    private let path: String

    init(lines: String, path: String) {
        self.lines = lines
        self.path = path
    }

    func append(_ message: String) {}
    func snapshot() -> String { lines }
    func logPath() -> String { path }
}

@Suite struct UpdateLoggingTests {
    @Test func clipboardPayloadAppendsLogPathWhenSnapshotHasEntries() {
        let log = StubUpdateLog(lines: "line one\nline two", path: "/tmp/cmux-update.log")
        #expect(log.clipboardPayload() == "line one\nline two\nLog file: /tmp/cmux-update.log")
    }

    @Test func clipboardPayloadUsesNoLogsNoticeWhenSnapshotEmpty() {
        let log = StubUpdateLog(lines: "", path: "/tmp/cmux-update.log")
        #expect(log.clipboardPayload() == "No update logs captured.\nLog file: /tmp/cmux-update.log")
    }
}
