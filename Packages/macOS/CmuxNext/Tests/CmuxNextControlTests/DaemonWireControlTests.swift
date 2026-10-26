#if DEBUG
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextSettings
import Testing

/// `debug.daemon.wire` reports a recorder's counts under the keys the p05-ipc benches read, and
/// `{"reset": true}` returns the counts from before the reset, then zeroes traffic but not connections.
@Suite
struct DaemonWireControlTests {
    @Test func reportsTheCountsThenResetsTrafficButNotConnections() throws {
        let stats = DaemonWireStats()
        let attach = stats.recorder()
        attach.connectionOpened(.terminalAttach, bridged: true)
        attach.bytesRead(100)
        attach.lineRead(.event)
        attach.lineRead(.reply)
        attach.decoded()
        attach.decoded()
        attach.decoded()
        attach.lineWritten(bytes: 7)
        attach.outputCopied(40)
        let control = stats.recorder()
        control.connectionOpened(.control, bridged: false)
        control.connectionClosed(.control)

        let first = try #require(DaemonWireControl.report(["reset": .bool(true)], stats: stats).objectValue)
        #expect(first["bytes_read"]?.intValue == 100)
        #expect(first["bytes_written"]?.intValue == 7)
        #expect(first["lines_read"]?.intValue == 2)
        #expect(first["lines_written"]?.intValue == 1)
        let frames = try #require(first["frames_read"]?.objectValue)
        #expect(frames["event"]?.intValue == 1)
        #expect(frames["reply"]?.intValue == 1)
        #expect(frames["dropped_reply"]?.intValue == 0)
        #expect(frames["stream_item"]?.intValue == 0)
        #expect(frames["stream_end"]?.intValue == 0)
        #expect(frames["ignored"]?.intValue == 0)
        #expect(first["json_decodes"]?.intValue == 3)
        #expect(first["decodes_per_line"]?.doubleValue == 1.5)
        #expect(first["output_bytes_copied_app"]?.intValue == 40)
        let connections = try #require(first["connections"]?.objectValue)
        #expect(connections["opened_total"]?.intValue == 2)
        #expect(connections["opened"]?.objectValue?["terminal_attach"]?.intValue == 1)
        #expect(connections["opened"]?.objectValue?["control"]?.intValue == 1)
        #expect(connections["closed"]?.objectValue?["control"]?.intValue == 1)
        #expect(connections["open"]?.objectValue?["terminal_attach"]?.intValue == 1)
        #expect(connections["open"]?.objectValue?["control"]?.intValue == 0)
        #expect(first["bridge_spawns"]?.objectValue?["terminal_attach"]?.intValue == 1)
        #expect(first["bridge_spawns_total"]?.intValue == 1)

        let second = try #require(DaemonWireControl.report([:], stats: stats).objectValue)
        for key in ["bytes_read", "bytes_written", "lines_read", "lines_written", "json_decodes", "output_bytes_copied_app"] {
            #expect(second[key]?.intValue == 0, "\(key) after the reset")
        }
        #expect(second["frames_read"]?.objectValue?.values.allSatisfy { $0.intValue == 0 } == true)
        #expect(second["decodes_per_line"]?.doubleValue == 0)
        #expect(second["connections"] == first["connections"])
        #expect(second["bridge_spawns_total"]?.intValue == 1)
    }

    /// `methods` lists each timed method by its schema `id` (the join key of the daemon's
    /// `server-stats` `ipc_methods` rows) with the daemon's percentile keys, its timed-out and
    /// abandoned requests, `other` with a null id, and a reset empties it.
    @Test func reportsSendToReplyByMethod() throws {
        let stats = DaemonWireStats(methods: [.init(id: 0x0101, name: "identify")])
        let recorder = stats.recorder()
        recorder.replied(recorder.requestSent("identify"))
        recorder.timedOut(recorder.requestSent("identify"))
        recorder.abandoned(recorder.requestSent("identify"))
        recorder.replied(recorder.requestSent("no-such-command"))

        let report = try #require(DaemonWireControl.report(["reset": .bool(true)], stats: stats).objectValue)
        let methods = try #require(report["methods"]?.arrayValue)
        #expect(methods.count == 2)
        let identify = try #require(methods.first?.objectValue)
        #expect(identify["method"]?.stringValue == "identify")
        #expect(identify["id"]?.intValue == 0x0101)
        #expect(identify["timed_out"]?.intValue == 1)
        #expect(identify["abandoned"]?.intValue == 1)
        let timing = try #require(identify["send_to_reply_us"]?.objectValue)
        #expect(timing["count"]?.intValue == 2, "the reply and the timeout")
        for key in ["p50", "p95", "p99", "max"] { #expect(timing[key]?.doubleValue != nil, "\(key)") }
        let other = try #require(methods.last?.objectValue)
        #expect(other["method"]?.stringValue == DaemonWireStats.Method.otherName)
        #expect(other["id"] == .null)

        let after = try #require(DaemonWireControl.report([:], stats: stats).objectValue)
        #expect(after["methods"] == .array([]))
    }

    /// Without `reset` the report changes nothing: a second report reads the same counts.
    @Test func aReportWithoutResetKeepsTheCounts() {
        let stats = DaemonWireStats()
        let recorder = stats.recorder()
        recorder.bytesRead(5)
        recorder.lineRead(.ignored)
        #expect(DaemonWireControl.report([:], stats: stats) == DaemonWireControl.report(["reset": .bool(false)], stats: stats))
        #expect(stats.snapshot().bytesRead == 5)
    }
}
#endif
