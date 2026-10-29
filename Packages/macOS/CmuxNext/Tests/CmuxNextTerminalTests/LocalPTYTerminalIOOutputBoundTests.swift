@testable import CmuxNextTerminal
import Darwin
import Foundation
import Testing

/// The local PTY's `events` hold at most `outputBound` bytes the session has not taken, plus the one
/// read chunk that filled them: the read source pauses there and resumes once the session took half
/// (Mojo's data pipe capacity, mojo/core/data_pipe_producer_dispatcher.cc). The stream
/// was unbounded, so a shell printing faster than the session took its output grew it without limit.
@Suite(.serialized, .timeLimit(.minutes(3))) struct LocalPTYTerminalIOOutputBoundTests {
    /// A shell prints 100 MB to a session that takes nothing until it holds the bound, then takes it all
    /// at once, over and over: the stream never holds more than the bound and one chunk, the reader is
    /// paused at every stall, and every byte arrives, in order.
    @Test func aStalledSessionHoldsAtMostTheBoundAndLosesNoByte() async throws {
        let total = 100 << 20
        let bound = 256 << 10
        let script = try FloodScript(bytes: total)
        defer { script.remove() }
        let io = try LocalPTYTerminalIO(shell: script.path, workingDirectory: "/", installedTerminfo: false, outputBound: bound)
        defer { io.terminate() }

        // The bound, the chunk that filled it, and the PTY's own buffer the last drain reads past the
        // window once the shell exited (less than one more chunk).
        let ceiling = bound + 2 * LocalPTYTerminalIO.readChunkCapacity
        let pattern = Data(repeating: FloodScript.byte, count: LocalPTYTerminalIO.readChunkCapacity)
        var received = 0
        var withheld = 0
        var mostBuffered = 0
        var foreignChunks = 0
        var pausedAtStall: [Bool] = []
        for await event in io.events {
            guard case .output(let data) = event else { continue }
            if data != pattern.prefix(data.count) { foreignChunks += 1 }
            received += data.count
            withheld += data.count
            mostBuffered = max(mostBuffered, io.bufferedOutputBytes)
            guard withheld >= bound else { continue }
            pausedAtStall.append(io.isOutputPaused)
            io.outputConsumed(withheld)
            withheld = 0
        }
        io.outputConsumed(withheld)

        #expect(received == total, "every byte the shell printed arrives")
        #expect(foreignChunks == 0, "only the shell's bytes, in order")
        #expect(mostBuffered <= ceiling, "the stream held \(mostBuffered) bytes, past \(ceiling)")
        #expect(pausedAtStall.count >= total / ceiling, "the session stalled at every bound")
        // The last drain after the shell exits reads the PTY's own buffer past the window, so only the
        // last stall may find the reader running.
        #expect(pausedAtStall.dropLast().allSatisfy { $0 }, "the reader kept reading while the session held the bound")
    }

    /// A shell that ends while the reader is paused still ends the stream: the paused read source resumes
    /// so that it is cancelled and released (releasing a suspended dispatch source traps).
    @Test func aShellThatEndsWhileTheReaderIsPausedEndsTheStream() async throws {
        let bound = 64 << 10
        let script = try FloodScript(bytes: 4 << 20)
        defer { script.remove() }
        let io = try LocalPTYTerminalIO(shell: script.path, workingDirectory: "/", installedTerminfo: false, outputBound: bound)
        defer { io.terminate() }

        var withheld = 0
        var hungUp = false
        var exited = false
        for await event in io.events {
            switch event {
            case .output(let data):
                withheld += data.count
                if withheld >= bound, !hungUp {
                    #expect(io.isOutputPaused)
                    hungUp = true
                    io.terminate()
                }
            case .exited: exited = true
            default: break
            }
        }
        #expect(hungUp && exited, "the stream ends with .exited though its reader was paused")
    }
}

/// An executable script, the "shell" the PTY runs, that prints `bytes` copies of ``byte`` and exits.
private struct FloodScript {
    static let byte = UInt8(ascii: "a")

    let directory: URL
    var path: String { directory.appendingPathComponent("flood.sh").path }

    init(bytes: Int) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pty-flood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // ONLCR only rewrites newlines, so the PTY passes these bytes through unchanged.
        let body = "#!/bin/sh\nhead -c \(bytes) /dev/zero | LC_ALL=C tr '\\000' 'a'\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
