// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import Darwin
import Foundation
import Testing

/// A write after the reader left answers false and never raises SIGPIPE, for a pipe (a child's
/// stdin, as the Screen Sharing worker writes to its cmux.rd/1 host) and for a socket, in a
/// process that does not ignore SIGPIPE: the test runner, where a raised SIGPIPE kills the run.
@Suite struct LineChannelNoSigpipeTests {
    @Test func aWriteToAPipeWhoseReaderLeftFailsWithoutASignal() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        let channel = LineChannel(read: -1, write: fds[1])
        close(fds[0])
        #expect(channel.write(RemoteWire.line(["stop": true])) == false)
        channel.closeWrite()
    }

    @Test func aWriteToASocketWhosePeerLeftFailsWithoutASignal() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let channel = LineChannel(socket: pair[0])
        close(pair[1])
        #expect(channel.write(RemoteWire.line(["stop": true])) == false)
        close(pair[0])
    }
}
