import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app's daemon sockets are close-on-exec (request-origin.md, peer key caveat): a program
/// the app execs must not inherit a connection whose peer key is the app's audit token.
@Suite(.timeLimit(.minutes(1))) struct DaemonSocketCloexecTests {
    /// Exit status of `/bin/sh -c 'true <&FD'` spawned with plain posix_spawn (no
    /// POSIX_SPAWN_CLOEXEC_DEFAULT): 0 only when the child inherited `fd`.
    static func childInherits(_ fd: Int32) -> Bool {
        // Test on a reserved descriptor number so unrelated inherited descriptors cannot
        // make the shell redirection succeed after the real descriptor closes on exec.
        let flags = fcntl(fd, F_GETFD, 0)
        let probe = fcntl(fd, F_DUPFD, 128)
        guard flags >= 0, probe >= 0 else {
            if probe >= 0 { close(probe) }
            return false
        }
        guard fcntl(probe, F_SETFD, flags) == 0 else {
            close(probe)
            return false
        }
        defer { close(probe) }
        let arguments = ["/bin/sh", "-c", "true <&\(probe)"].map { $0.withCString { strdup($0) } } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", nil, nil, arguments, nil) == 0 else { return false }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status == 0
    }

    @Test func anExecdChildDoesNotInheritTheDaemonSocket() throws {
        let server = try FakeDaemonServer { _ in [] }
        defer { server.stop() }
        let transport = try LineTransport(path: server.path)
        defer { transport.close() }
        let fd = transport.descriptorForTesting
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(!Self.childInherits(fd))
        // Control: a copy without close-on-exec is inherited, so the probe can see one.
        let copy = dup(fd)
        defer { close(copy) }
        #expect(Self.childInherits(copy))
    }
}
