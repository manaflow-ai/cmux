import CmuxNextCrashReporting
import Foundation
import Testing

/// The acpmux daemon's panics reach Sentry like the owner's (2026-10-14: a
/// sort panic in a daemon request task reached only daemon.log).
@Suite struct RustPanicForwarderTests {
    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rust-panic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func line(_ fields: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: fields)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    @Test func anAcpmuxPanicLineIsSentWithItsOwnProcessAndFingerprint() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RustPanicSource.acpmuxLog(acpmuxHome: dir)
        #expect(log.lastPathComponent == "panics.jsonl")
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: .acpmux, capture: { _ in })
        // The first read only marks the log read.
        #expect(forwarder.forwardNew().isEmpty)
        let location = "crates/acpmux/src/hub/mod.rs:941:5"
        try Self.append(Self.line(["process": "acpmux", "message": "user-provided comparison function does not correctly implement a total order",
                                   "location": location, "thread": "tokio-rt-worker", "test": false,
                                   "backtrace": "0: acpmux::hub::newest_first"]), to: log)
        try Self.append(Self.line(["process": "acpmux", "message": "test", "location": location, "thread": "t", "test": true]), to: log)

        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        let event = sent[0]
        #expect(event.fingerprint == ["acpmux-panic", location])
        #expect(event.tags?["process"] == "acpmux")
        #expect(event.tags?["crash_source"] == "acpmux_panic_log")
        #expect(event.tags?["thread"] == "tokio-rt-worker")
        #expect(event.exceptions?.first?.type == "RustPanic")
        #expect(event.message?.formatted.hasPrefix("acpmux daemon panic at \(location)") == true)
        #expect(forwarder.forwardNew().isEmpty)
    }

    @Test func theOwnerSourceKeepsItsEarlierFingerprint() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "owner-panics-s.jsonl")
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            capture: { _ in })
        _ = forwarder.forwardNew()
        try Self.append(Self.line(["message": "boom", "location": "a.rs:1:1", "thread": "w"]), to: log)
        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        #expect(sent[0].fingerprint == ["owner-panic", "a.rs:1:1"])
        #expect(sent[0].tags?["process"] == "cmux-tui")
    }

    @Test func aTerminalHostLineInTheOwnerLogIsLabeledAsTheHost() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "owner-panics-s.jsonl")
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            capture: { _ in })
        _ = forwarder.forwardNew()
        let location = "crates/vt/src/parser.rs:12:5"
        try Self.append(Self.line(["source": "cmux-tui-host", "message": "index out of bounds", "location": location,
                                   "thread": "terminal-host-parser", "test": false,
                                   "backtrace": "0: vt::parser::advance"]), to: log)
        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        #expect(sent[0].fingerprint == ["host-panic", location])
        #expect(sent[0].tags?["process"] == "cmux-tui-host")
        #expect(sent[0].tags?["crash_source"] == "terminal_host_crash")
        #expect(sent[0].extra?["backtrace"] as? String == "0: vt::parser::advance")
        #expect(sent[0].message?.formatted.hasPrefix("cmux-tui terminal host panic at \(location)") == true)
        #expect(RustPanicSource.acpmux.labeling(lineSource: "cmux-tui-host") == .acpmux)
    }
}
