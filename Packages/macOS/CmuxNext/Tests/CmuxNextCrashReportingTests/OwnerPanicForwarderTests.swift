@testable import CmuxNextCrashReporting
import Foundation
import Sentry
import Synchronization
import Testing

/// cx-urd.59: the cmux-tui owner's panic log reaches Sentry, each line once,
/// never from before the first run or a time reports were off.
@Suite struct OwnerPanicForwarderTests {
    static func line(_ message: String, location: String = "crates/cmux-tui-core/src/mux.rs:42:9", test: Bool = false) throws -> String {
        let record: [String: Any] = ["session": "cmux-app", "message": message, "location": location,
                                     "thread": "journal-hooks", "owner_pid": 4242, "version": "0.65.0",
                                     "at_ms": 1, "test": test, "backtrace": "0: std::panicking::begin_panic"]
        let data = try JSONSerialization.data(withJSONObject: record)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    final class Fixture: Sendable {
        let root = FileManager.default.temporaryDirectory.appending(path: "owner-panics-\(UUID().uuidString)")
        let sent = Mutex<[String]>([])
        var log: URL { OwnerPanicForwarder.log(stateRoot: root, session: "cmux-app") }

        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        func forwarder(sends: Bool = true) -> OwnerPanicForwarder {
            OwnerPanicForwarder(log: log, stateFile: root.appending(path: "state.json"), sends: sends,
                                capture: { [self] event in sent.withLock { $0.append(event.exceptions?.first?.value ?? "") } })
        }

        func append(_ text: String) throws {
            if !FileManager.default.fileExists(atPath: log.path) { try Data().write(to: log) }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
    }

    @Test func aLineBecomesAnEventGroupedByThePanicSite() throws {
        let event = try #require(OwnerPanicForwarder.event(fromLine: Data(try Self.line("index out of bounds").utf8)))
        #expect(event.exceptions?.first?.type == "RustPanic")
        #expect(event.exceptions?.first?.value == "index out of bounds")
        #expect(event.fingerprint == ["owner-panic", "crates/cmux-tui-core/src/mux.rs:42:9"])
        #expect(event.tags?["process"] == "cmux-tui")
        #expect(event.tags?["thread"] == "journal-hooks")
        #expect(event.extra?["backtrace"] as? String == "0: std::panicking::begin_panic")
        #expect(OwnerPanicForwarder.event(fromLine: Data(try Self.line("x", test: true).utf8)) == nil, "test panics are skipped")
        #expect(OwnerPanicForwarder.event(fromLine: Data("{\"not\":\"a panic\"}".utf8)) == nil)
    }

    @Test func eachNewLineIsSentOnceAndOlderLinesNever() throws {
        let fixture = try Fixture()
        try fixture.append(try Self.line("before the first run"))
        #expect(fixture.forwarder().forwardNew().isEmpty, "the first run only marks the log read")
        try fixture.append(try Self.line("first") + Self.line("second"))
        let third = try Self.line("third")
        let cut = third.index(third.startIndex, offsetBy: third.count / 2)
        try fixture.append(String(third[..<cut]))
        #expect(fixture.forwarder().forwardNew().count == 2, "a line still being written waits")
        #expect(fixture.forwarder().forwardNew().isEmpty, "never twice")
        try fixture.append(String(third[cut...]))
        #expect(fixture.forwarder().forwardNew().count == 1)
        #expect(fixture.sent.withLock { $0 } == ["first", "second", "third"])
    }

    @Test func linesFromATimeReportsWereOffAreNeverSent() throws {
        let fixture = try Fixture()
        try fixture.append(try Self.line("seed"))
        fixture.forwarder(sends: false).forwardNew()
        try fixture.append(try Self.line("while off"))
        #expect(fixture.forwarder(sends: false).forwardNew().isEmpty)
        #expect(fixture.forwarder().forwardNew().isEmpty, "reports on later: the old line stays unsent")
        #expect(fixture.sent.withLock { $0 }.isEmpty)
    }
}
