import Darwin
import Foundation
import Testing
@testable import CmuxNextApp

/// The app's own SIGPIPE policy, and what children inherit from it.
@Suite(.serialized)
struct ChildSignalDefaultsTests {
    /// The `sigignore` mask of a child started the way the app starts
    /// non-PTY children (Foundation `Process`), as reported by ps.
    private func childIgnoredMask() throws -> UInt64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ps -o sigignore= -p $$"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt64(text, radix: 16) ?? .max
    }

    private func bit(_ signal: Int32) -> UInt64 { 1 << UInt64(signal - 1) }

    @Test func childrenStartWithDefaultDispositions() throws {
        ChildSignalDefaults.installAppSignalPolicy()
        let mask = try childIgnoredMask()
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] {
            #expect(mask & bit(signal) == 0, "signal \(signal) is ignored in a child (mask \(String(mask, radix: 16)))")
        }
    }

    @Test func aWriteToAClosedPipeFailsWithEPIPE() throws {
        ChildSignalDefaults.installAppSignalPolicy()
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        close(fds[0])
        var byte: UInt8 = 1
        let written = write(fds[1], &byte, 1)
        let failure = errno
        close(fds[1])
        #expect(written == -1)
        #expect(failure == EPIPE)
    }
}
