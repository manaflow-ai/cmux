// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteComputerUse
import CmuxRemoteWire
import Darwin
import Foundation
import os
import Testing

/// LineChannel's descriptor lifetime, which the preview session and the daemon handoff rely on:
/// a write or close after the close never reaches a reused descriptor number, close() never waits
/// on a stuck writer, and shutdown() leaves the close to the owner. These tests watch descriptor
/// numbers the kernel hands out again, so they run one at a time; when another test took the freed
/// number first (other suites still run in parallel), the race cannot be shown and the test says so
/// and passes rather than fail on the scheduling.
@Suite(.serialized) struct LineChannelDescriptorTests {
    /// The freed number went to another descriptor before the test could take it.
    private static func notReused(_ test: String) {
        print("\(test): the freed descriptor number was taken by another test; the race was not exercised this run")
    }

    /// A preview session's channel after it ended: a write queued before the close (the encoder's
    /// last frames, a status, a still) must never reach the descriptor number once the next
    /// connection reuses it (round-2 review of f9ff124: agent A's frames landed in B's stream).
    @Test func aWriteAfterCloseNeverReachesAReusedDescriptor() throws {
        var first: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0)
        let channel = LineChannel(socket: first[0])
        let number = first[0]
        channel.shutdown()
        #expect(!channel.write(Data("after shutdown\n".utf8)), "a shut-down channel refuses writes")
        channel.close()
        close(first[1])
        // The next connection gets the lowest free number: the one the closed channel had.
        var second: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0)
        defer { close(second[0]); close(second[1]) }
        let reused = second[0] == number ? second[0] : (second[1] == number ? second[1] : -1)
        guard reused >= 0 else { return Self.notReused("aWriteAfterCloseNeverReachesAReusedDescriptor") }
        let peer = reused == second[0] ? second[1] : second[0]
        #expect(!channel.write(Data("agent A's frame\n".utf8)), "a closed channel refuses writes")
        channel.close() // a second close must not close the reused number either
        #expect(fcntl(reused, F_GETFD) != -1, "the reused descriptor is still open")
        _ = fcntl(peer, F_SETFL, O_NONBLOCK)
        var byte: UInt8 = 0
        #expect(read(peer, &byte, 1) == -1 && errno == EAGAIN, "nothing reached the reused descriptor")
    }

    /// A writer blocked in a full socket (the peer stopped reading) must not hold up close():
    /// RemoteHost closes the old daemon's channel during a handoff, and a hang there keeps the new
    /// daemon from its hello reply (full review of a0f8d73).
    @Test func closeDoesNotWaitForAWriterStuckInAFullSocket() throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { Darwin.close(fds[1]) }
        let channel = LineChannel(socket: fds[0])
        let wrote = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let writerDone = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        Thread {
            started.signal()
            let ok = channel.write(Data(repeating: 0x41, count: 16 * 1024 * 1024)) // far past the socket buffer
            wrote.withLock { $0 = ok }
            writerDone.signal()
        }.start()
        started.wait()
        #expect(writerDone.wait(timeout: .now() + 0.3) == .timedOut, "the writer is stuck: nobody reads")
        let closed = DispatchSemaphore(value: 0)
        Thread { channel.close(); closed.signal() }.start()
        #expect(closed.wait(timeout: .now() + 5) == .success, "close() returns")
        #expect(writerDone.wait(timeout: .now() + 5) == .success, "and the writer wakes")
        #expect(wrote.withLock { $0 } == false)
        channel.shutdown() // after a close: a no-op, never a reused number
        channel.close()
    }

    /// A channel with its own write descriptor (a pipe pair): a closeWrite() that lands while
    /// close() is between its shutdown and its close closes the write side, and close() must not
    /// close that number again once another descriptor reuses it (review of f4956b5).
    @Test func closeRacingCloseWriteNeverClosesTheWriteNumberTwice() throws {
        var inbound: [Int32] = [-1, -1], outbound: [Int32] = [-1, -1]
        #expect(pipe(&inbound) == 0 && pipe(&outbound) == 0)
        defer { Darwin.close(inbound[1]); Darwin.close(outbound[0]) }
        let writeNumber = outbound[1]
        let reused = OSAllocatedUnfairLock<Int32>(initialState: -1)
        let box = OSAllocatedUnfairLock<LineChannel?>(uncheckedState: nil)
        let channel = LineChannel(read: inbound[0], write: outbound[1], afterShutdown: {
            // The race: closeWrite() runs now, and the freed write number is taken at once.
            box.withLockUnchecked { $0 }?.closeWrite()
            reused.withLock { $0 = open("/dev/null", O_RDONLY) }
        })
        box.withLockUnchecked { $0 = channel }
        channel.close()
        let number = reused.withLock { $0 }
        defer { Darwin.close(number) }
        guard number == writeNumber else { return Self.notReused("closeRacingCloseWriteNeverClosesTheWriteNumberTwice") }
        #expect(fcntl(number, F_GETFD) != -1, "close() closed the reused write number a second time")
        #expect(!channel.write(Data("late\n".utf8)))
    }

    /// The daemon handoff shuts the old daemon's channel down instead of closing it: its reader,
    /// blocked in a read, wakes and ends while its descriptor stays open, and only the reader's own
    /// close (after its last read) frees the number (review of f4956b5, RemoteHost's handoff).
    @Test func shutdownWakesAReaderAndLeavesTheDescriptorForItsOwnClose() throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { Darwin.close(fds[1]) }
        let channel = LineChannel(socket: fds[0])
        let ended = DispatchSemaphore(value: 0)
        Thread {
            while channel.readLine() != nil {}
            ended.signal()
        }.start()
        #expect(ended.wait(timeout: .now() + 0.2) == .timedOut, "the reader is blocked")
        channel.shutdown()
        #expect(ended.wait(timeout: .now() + 5) == .success, "shutdown() wakes the reader")
        #expect(fcntl(fds[0], F_GETFD) != -1, "and leaves the descriptor open")
        channel.close() // the owner's close (after the reader's last read) frees it
    }
}
