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

    /// p09-observability-099: the app hosts, the browser host, `cmux mcp serve` and acpmux's agent
    /// hosts each write their own log, at the path the Rust side names, and group apart in Sentry.
    @Test(arguments: [
        (RustPanicSource.appHost, "app-host-panics.jsonl", "app-host-panic", "app_host_panic_log", "cmux-app-host"),
        (RustPanicSource.browserHost, "browser-host-panics.jsonl", "browser-host-panic", "browser_host_panic_log",
         "cmux-browser-host"),
        (RustPanicSource.mcp, "mcp-panics.jsonl", "mcp-panic", "mcp_panic_log", "cmux-mcp"),
        (RustPanicSource.agentHost, "agent-host-panics.jsonl", "agent-host-panic", "agent_host_panic_log",
         "acpmux-agent-host"),
    ])
    func aHelperPanicLineIsSentWithItsOwnProcessAndFingerprint(
        source: RustPanicSource, file: String, prefix: String, crashSource: String, process: String
    ) throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helperLog = source == .agentHost ? RustPanicSource.agentHostLog(acpmuxHome: dir)
            : source.helperLog(stateRoot: dir)
        let log = try #require(helperLog)
        #expect(log == dir.appending(path: file))
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: source, capture: { _ in })
        #expect(forwarder.forwardNew().isEmpty)
        let location = "crates/x/src/main.rs:1:1"
        try Self.append(Self.line(["process": process, "message": "boom", "location": location, "thread": "w",
                                   "pid": 42, "test": false]), to: log)
        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        #expect(sent[0].fingerprint == [prefix, location])
        #expect(sent[0].tags?["process"] == process)
        #expect(sent[0].tags?["crash_source"] == crashSource)
    }

    @Test func onlyTheOwnersHelpersHaveALogAtItsStateRoot() {
        let root = URL(filePath: "/state")
        #expect(RustPanicSource.owner.helperLog(stateRoot: root) == nil)
        #expect(RustPanicSource.acpmux.helperLog(stateRoot: root) == nil)
        #expect(RustPanicSource.agentHost.helperLog(stateRoot: root) == nil)
        let home = URL(filePath: "/acpmux")
        #expect(RustPanicSource.helperLogs(stateRoot: root, acpmuxHome: nil).map { $0.0.process }
            == ["cmux-app-host", "cmux-browser-host", "cmux-mcp"])
        let all = RustPanicSource.helperLogs(stateRoot: root, acpmuxHome: home)
        #expect(all.last?.0 == .agentHost)
        #expect(all.last?.1 == home.appending(path: "agent-host-panics.jsonl"))
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
