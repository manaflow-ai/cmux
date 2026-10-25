@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// The Chromium host's process and wire with a real child process: a shell
/// that copies fd 3 (frames from cmux) to fd 4 (frames to cmux) stands in for the host. A host killed with SIGKILL
/// ends only itself: its exit is reported with the signal, and the wire
/// ends without touching this process.
@Suite struct ChromiumHostProcessTests {
    private static let echo = URL(filePath: "/bin/sh")
    private static let echoArguments = ["-c", "exec /bin/cat <&3 >&4"]

    @Test func framesRoundTripThroughAChildProcess() async throws {
        let launcher = ChromiumHostLauncher()
        let handle = try launcher.launch(executable: Self.echo, arguments: Self.echoArguments)
        let connection = ChromiumHostConnection(readFD: handle.readFD, writeFD: handle.writeFD)
        var ping = ChromiumHostFrame(.ping, t0: 42)
        ping.seq = 7
        #expect(connection.send(ping))
        #expect(connection.send(ChromiumHostFrame(.navigate, payload: Array("https://example.com/".utf8))))
        var iterator = connection.frames.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first == ping)
        #expect(second?.text == "https://example.com/")
        kill(handle.pid, SIGKILL)
        _ = await launcher.exit(of: handle.pid)
        launcher.reap(handle.pid)
        connection.close()
    }

    @Test func aKilledHostReportsItsSignalAndEndsTheWire() async throws {
        let launcher = ChromiumHostLauncher()
        let handle = try launcher.launch(executable: Self.echo, arguments: Self.echoArguments)
        let connection = ChromiumHostConnection(readFD: handle.readFD, writeFD: handle.writeFD)
        #expect(kill(handle.pid, SIGKILL) == 0)
        let exit = await launcher.exit(of: handle.pid)
        #expect(exit == ChromiumHostExit(signal: SIGKILL, status: nil))
        // Not reaped yet: the pid stays this host's, so a late kill cannot reach another process.
        #expect(kill(handle.pid, 0) == 0)
        launcher.reap(handle.pid)
        #expect(kill(handle.pid, 0) == -1)
        // The wire ends: the stream finishes (EOF), and later sends fail without a SIGPIPE.
        var iterator = connection.frames.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(!connection.send(ChromiumHostFrame(.ping)))
    }

    @Test func anExitStatusIsReported() async throws {
        let launcher = ChromiumHostLauncher()
        let handle = try launcher.launch(executable: Self.echo, arguments: ["-c", "exit 3"])
        let exit = await launcher.exit(of: handle.pid)
        #expect(exit == ChromiumHostExit(signal: nil, status: 3))
        launcher.reap(handle.pid)
        ChromiumHostConnection(readFD: handle.readFD, writeFD: handle.writeFD).close()
    }

    @Test func aHostThatStopsReadingEndsTheConnection() async throws {
        let launcher = ChromiumHostLauncher()
        // Never reads fd 3.
        let handle = try launcher.launch(executable: Self.echo, arguments: ["-c", "exec /bin/sleep 30"])
        let connection = ChromiumHostConnection(readFD: handle.readFD, writeFD: handle.writeFD)
        let frame = ChromiumHostFrame(.mouse, v: [1, 2, 0, 0, 0, 0])
        var sent = 0
        // Bounded: the send buffer holds about sendBuffer / 64 frames, and the
        // socket's receive side a little more.
        // Never blocks: a write that would wait fails instead (cmux calls this on its main thread).
        let started = ContinuousClock.now
        while sent < 100_000, connection.send(frame) { sent += 1 }
        #expect(sent < 100_000)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!connection.send(frame))
        #expect(connection.endedByProtocolError)
        kill(handle.pid, SIGKILL)
        _ = await launcher.exit(of: handle.pid)
        launcher.reap(handle.pid)
    }
}
