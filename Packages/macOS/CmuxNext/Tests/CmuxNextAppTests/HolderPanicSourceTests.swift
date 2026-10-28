import CmuxNextCrashReporting
import Foundation
import Testing

/// The PTY holder's panic lines (cmux-panic-log's std-only writer)
/// reach Sentry under their own process and fingerprint.
@Suite struct HolderPanicSourceTests {
    @Test func theHolderLogIsInTheUsersHolderSocketDirectory() {
        #expect(RustPanicSource.holderLog(userID: 501).path(percentEncoded: false)
            == "/tmp/cmux-hd-501/holder-panics.jsonl")
    }

    @Test func aHolderPanicLineIsSentWithItsOwnProcessAndFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "holder-panic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "holder-panics.jsonl")
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: .holder, capture: { _ in })
        // The first read only marks the log read.
        #expect(forwarder.forwardNew().isEmpty)
        // The line as the Rust writer prints it: hand-escaped, keys in its order.
        let location = "crates/cmux-holder/src/holder.rs:12:9"
        let line = #"{"process":"cmux-holder","holder_pid":42,"holder_socket":"0f.sock","os":"macos","#
            + #""message":"bad \"frame\"\nlen","location":"\#(location)","thread":"holder-loop","#
            + #""at_ms":1,"test":false,"backtrace":"0: cmux_holder::holder"}"# + "\n"
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()

        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        #expect(sent[0].fingerprint == ["holder-panic", location])
        #expect(sent[0].tags?["process"] == "cmux-holder")
        #expect(sent[0].tags?["crash_source"] == "holder_panic_log")
        #expect(sent[0].tags?["thread"] == "holder-loop")
        #expect(sent[0].exceptions?.first?.value == "bad \"frame\"\nlen")
    }
}
