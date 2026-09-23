import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite
struct AgentRestoreLaunchLeaseTests {
    @Test("Two app instances cannot claim the same account and conversation")
    func sharedClaim() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID().uuidString
        let first = try AgentRestoreLaunchLease(directory: directory, account: "/codex", sessionID: session)
        let second = try AgentRestoreLaunchLease(directory: directory, account: "/codex", sessionID: session.lowercased())
        #expect(try first.tryAcquire())
        #expect(try !second.tryAcquire())
        first.release()
        #expect(try second.tryAcquire())
    }

    @Test("Independent accounts and conversations do not serialize behind each other")
    func independentClaims() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID().uuidString
        let first = try AgentRestoreLaunchLease(directory: directory, account: "/one", sessionID: session)
        let otherAccount = try AgentRestoreLaunchLease(directory: directory, account: "/two", sessionID: session)
        let otherSession = try AgentRestoreLaunchLease(directory: directory, account: "/one", sessionID: UUID().uuidString)
        #expect(try first.tryAcquire())
        #expect(try otherAccount.tryAcquire())
        #expect(try otherSession.tryAcquire())
    }

    @Test("The lease survives a zsh-to-sh exec chain")
    func wrapperExecRetainsLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try AgentRestoreLaunchLease(
            directory: directory, account: "/codex", sessionID: UUID().uuidString
        )
        #expect(try lease.tryAcquire())
        let path = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try lease.inheritAcrossExec()

        // The exec'd process must possess the inode itself. Merely observing
        // contention would pass even if only the parent retained the lease.
        let script = """
        import os, sys
        expected = os.stat(sys.argv[1])
        for name in os.listdir('/dev/fd'):
            try:
                current = os.fstat(int(name))
                if current.st_dev == expected.st_dev and current.st_ino == expected.st_ino:
                    sys.exit(0)
            except OSError:
                pass
        sys.exit(1)
        """
        let arguments = [
            "/bin/zsh", "-f", "-c",
            "exec /bin/sh -c 'exec /usr/bin/python3 \"$@\"' sh \"$@\"",
            "zsh", "-c", script, path.path
        ]
        var argv = arguments.map { strdup($0) } + [nil]
        var environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer {
            for value in argv { free(value) }
            for value in environment { free(value) }
        }
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { arguments in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, "/bin/zsh", nil, nil, arguments.baseAddress, environment.baseAddress)
            }
        }
        #expect(result == 0)
        guard result == 0 else { return }
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        #expect(status == 0)
    }
}
