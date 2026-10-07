import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The relay preamble of a daemon connection (`DaemonEndpoint.preamble`):
/// `cmux link`'s `link.dial` before the daemon protocol.
@Suite struct LinePreambleTests {
    @Test func onlyAnOkReplyPasses() throws {
        try LinePreamble.check(Data(#"{"ok":true,"path_state":"direct","relay_available":false}"#.utf8))
        #expect(throws: DaemonError.self) {
            try LinePreamble.check(Data(#"{"ok":false,"error_code":"not_authorized","path_state":"unreachable"}"#.utf8))
        }
        #expect(throws: DaemonError.self) { try LinePreamble.check(Data("garbage".utf8)) }
        #expect(throws: DaemonError.self) { try LinePreamble.check(Data(#"{"path_state":"direct"}"#.utf8)) }
    }

    /// The exchange writes the line, reads exactly one reply line and leaves
    /// the daemon's first byte after it unread.
    @Test func theExchangeConsumesOnlyTheReplyLine() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let reply = Array(#"{"ok":true}"#.utf8) + [10] + Array("D".utf8)
        _ = reply.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        try LinePreamble(fd: fds[0]).exchange(#"{"op":"link.dial","host":"inst_x","service":"owner_session"}"#)
        var sent = [UInt8](repeating: 0, count: 256)
        let count = read(fds[1], &sent, sent.count)
        #expect(String(decoding: sent.prefix(max(count, 0)), as: UTF8.self) == #"{"op":"link.dial","host":"inst_x","service":"owner_session"}"# + "\n")
        var next: UInt8 = 0
        #expect(read(fds[0], &next, 1) == 1)
        #expect(next == UInt8(ascii: "D"))
    }

    @Test func aRefusedDialEndsTheConnectAttempt() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let reply = Array(#"{"ok":false,"error_code":"not_authorized"}"#.utf8) + [10]
        _ = reply.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        #expect(throws: DaemonError.self) { try LinePreamble(fd: fds[0]).exchange("x") }
    }
}
