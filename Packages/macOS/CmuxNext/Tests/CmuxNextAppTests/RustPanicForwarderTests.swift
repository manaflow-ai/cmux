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

    /// cmux-cloud, optchat-chief and cmux-diff-sidecar write their logs where
    /// their `panic_log.rs` puts them, and each groups under its own process.
    @Test(arguments: [
        (RustPanicSource.cloud, "panics.jsonl", "cmux-cloud"),
        (RustPanicSource.optchatChief, "optchat/panics.jsonl", "optchat-chief"),
        (RustPanicSource.diffSidecar, ".sidecar-panics.jsonl", "cmux-diff-sidecar"),
    ])
    func eachShippedBinaryHasItsOwnLogAndLabels(source: RustPanicSource, relativeLog: String, process: String) throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log: URL = switch process {
        case "cmux-cloud": RustPanicSource.cloudLog(appDataDirectory: dir)
        case "optchat-chief": RustPanicSource.optchatChiefLog(muxHome: dir)
        default: RustPanicSource.diffSidecarLog(diffRoot: dir)
        }
        #expect(log.path == dir.appending(path: relativeLog).path)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: source, capture: { _ in })
        _ = forwarder.forwardNew()
        try Self.append(Self.line(["process": process, "message": "boom", "location": "src/main.rs:1:1",
                                   "thread": "main", "test": false]), to: log)
        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        #expect(sent[0].tags?["process"] == process)
        #expect(sent[0].fingerprint == [source.fingerprintPrefix, "src/main.rs:1:1"])
        #expect([RustPanicSource.owner, .acpmux].allSatisfy { $0.fingerprintPrefix != source.fingerprintPrefix })
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
}
