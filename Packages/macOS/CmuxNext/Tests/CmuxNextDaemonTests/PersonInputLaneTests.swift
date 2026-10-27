import CmuxNextIPC
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// The app half of the person-input lane (p01-process-235): a person's input line leaves the socket writer
/// before the control lines queued ahead of it, and lines of one priority keep their order.
@Suite(.serialized, .timeLimit(.minutes(1))) struct PersonInputLaneTests {
    /// Control lines queued before the key, each `padding` long: 4 MiB, far past the socket buffers, so most
    /// of them still wait in the writer when the key is written.
    static let controlLines = 128
    static let padding = String(repeating: "x", count: 32 << 10)

    @Test func aPersonKeyLeavesBeforeTheQueuedControlLines() throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        for _ in 0..<Self.controlLines {
            _ = transport.submit(.discard(cmd: "ping", onError: nil)) { id in
                Data(#"{"id":\#(id),"cmd":"ping","pad":"\#(Self.padding)"}"#.utf8)
            }
        }
        let key = transport.submit(.discard(cmd: "send-key", onError: nil), priority: .input) { id in
            Data(#"{"id":\#(id),"cmd":"send-key","surface":1,"keys":["a"]}"#.utf8)
        }
        let keyID = try key.get()
        var ids: [UInt64] = []
        while ids.last != keyID {
            ids.append(try daemon.readRequestID())
        }
        #expect(ids.count < Self.controlLines, "the key left after \(ids.count - 1) of \(Self.controlLines) control lines")
        let control = Array(ids.dropLast())
        #expect(control == control.sorted(), "control lines left out of call order")
    }

    @Test func linesOfOnePriorityKeepTheirOrder() throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        var sent: [UInt64] = []
        for _ in 0..<16 {
            let key = transport.submit(.discard(cmd: "send", onError: nil), priority: .input) { id in
                Data(#"{"id":\#(id),"cmd":"send","surface":1,"text":"a"}"#.utf8)
            }
            sent.append(try key.get())
        }
        let read = try sent.map { _ in try daemon.readRequestID() }
        #expect(read == sent)
    }
}
