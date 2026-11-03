import CmuxNextTerminal
import Darwin
import Foundation
import Testing

/// The debug-only local PTY shell (`CMUX_NEXT_DEBUG_TERMINAL`) gets no app descriptor: after its fork every
/// parent descriptor without close-on-exec went through execve (a socket, a pipe, a descriptor received
/// between `recvmsg` and `FD_CLOEXEC`).
@Suite(.serialized) struct LocalPTYDescriptorTests {
    @Test func theShellInheritsNoDescriptorFromTheApp() async throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer { fds.forEach { close($0) } }
        // An inheritable descriptor: no close-on-exec.
        let flags = fcntl(fds[0], F_GETFD)
        try #require(fcntl(fds[0], F_SETFD, flags & ~FD_CLOEXEC) == 0)

        // /bin/bash, not /bin/sh: macOS's /bin/sh is a shim that starts bash itself; with it the red run saw no
        // inherited descriptor, so the check would not see this code path's leak.
        let io = try LocalPTYTerminalIO(shell: "/bin/bash", workingDirectory: "/", environment: ["PS1": ""])
        defer { io.terminate() }
        await io.write(Data("if [ -e /dev/fd/\(fds[0]) ]; then echo FD-OPEN; else echo FD-CLOSED; fi; exit\n".utf8))
        var output = ""
        // Whole output lines only: the echoed command line also names both words. ("\r\n" is one Character.)
        func lines() -> [Substring] { output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces)[...] } }
        for await event in io.events {
            if case .output(let data) = event { output += String(decoding: data, as: UTF8.self) }
            if lines().contains("FD-OPEN") || lines().contains("FD-CLOSED") { break }
        }
        #expect(lines().contains("FD-CLOSED") && !lines().contains("FD-OPEN"),
                "the shell has descriptor \(fds[0]) from the app: \(output.suffix(200))")
    }
}
