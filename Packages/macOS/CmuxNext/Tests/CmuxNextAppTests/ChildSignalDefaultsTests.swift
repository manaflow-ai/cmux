import Darwin
import Foundation
import Testing
@testable import CmuxNextApp

/// The app's own SIGPIPE policy, and what children inherit from it.
@Suite(.serialized)
struct ChildSignalDefaultsTests {
    /// Each signal's disposition in a child started with a plain
    /// `posix_spawn` and no attributes, as C code inside the app does
    /// (crashpad, Chromium helpers): perl reports an inherited ignored signal
    /// as IGNORE (macOS ps has no sigignore column). Foundation's `Process`
    /// sets POSIX_SPAWN_SETSIGDEF itself; this is the case it does not cover.
    private func childDispositions() throws -> [String: String] {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EIO) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        let script = "print join(q( ), map { $_ . q(=) . (defined $SIG{$_} ? $SIG{$_} : q(DEFAULT)) } qw(PIPE TERM INT HUP))"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/perl"), strdup("-e"), strdup(script), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/usr/bin/perl", &actions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        close(fds[1])
        guard spawned == 0 else { close(fds[0]); throw POSIXError(.EIO) }
        let text = String(decoding: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile(), as: UTF8.self)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        var result: [String: String] = [:]
        for pair in text.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    @Test func childrenStartWithDefaultDispositions() throws {
        ChildSignalDefaults.installAppSignalPolicy()
        let dispositions = try childDispositions()
        #expect(dispositions.count == 4, "\(dispositions)")
        for name in ["PIPE", "TERM", "INT", "HUP"] {
            #expect(dispositions[name] == "DEFAULT", "SIG\(name) in a child: \(dispositions[name] ?? "missing")")
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
