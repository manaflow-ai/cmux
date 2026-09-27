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
        // A parallel fork can retain a close-on-exec descriptor until exec.
        // Await the kernel release, just as a contending CLI does.
        try second.acquireAfterOwnerExit()
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

    /// Spawns a stand-in for the exec'd agent. It blocks until its stdin
    /// closes, then exits 1 if it could see the lease inode.
    private func spawnAgentStandIn(leasePath: String) throws -> (pid: pid_t, release: Int32) {
        var input: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw POSIXError(.EIO) }
        _ = fcntl(input[1], F_SETFD, FD_CLOEXEC)
        let script = """
        import os, sys
        expected = os.stat(sys.argv[1])
        sys.stdin.read()
        for name in os.listdir('/dev/fd'):
            try:
                current = os.fstat(int(name))
                if current.st_dev == expected.st_dev and current.st_ino == expected.st_ino:
                    sys.exit(1)
            except OSError:
                pass
        sys.exit(0)
        """
        let pid = try spawn(["/usr/bin/python3", "-c", script, leasePath], stdin: input[0])
        close(input[0])
        return (pid, input[1])
    }

    private func spawn(_ arguments: [String], stdin: Int32? = nil) throws -> pid_t {
        var argv = arguments.map { strdup($0) } + [nil]
        var environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer {
            for value in argv { free(value) }
            for value in environment { free(value) }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // Tests run in parallel: never leak another test's pipe into this child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        if let stdin { posix_spawn_file_actions_adddup2(&actions, stdin, 0) }
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, arguments[0], &actions, &attributes, argv.baseAddress, environment.baseAddress)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }

    @Test("The exit watcher holds the lease until the launching process exits")
    func exitWatcherReleasesOnKernelExitNotification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID().uuidString
        let lease = try AgentRestoreLaunchLease(directory: directory, account: "/codex", sessionID: session)
        let path = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let agent = try spawnAgentStandIn(leasePath: path.path)

        // Start with an unlocked inode. Releasing a prior lock and immediately
        // reacquiring on a different descriptor races parallel tests' fork/exec:
        // their pre-exec children can briefly retain the old open description.
        // The separate transfer test exercises the actual gap-free handoff.
        let watcherLease = open(path.path, O_RDONLY | O_CLOEXEC)
        #expect(watcherLease >= 0)
        lease.release()
        #expect(flock(watcherLease, LOCK_EX | LOCK_NB) == 0)
        let contender = try AgentRestoreLaunchLease(directory: directory, account: "/codex", sessionID: session)
        var ready: [Int32] = [-1, -1]
        #expect(pipe(&ready) == 0)
        _ = fcntl(ready[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ready[1], F_SETFD, FD_CLOEXEC)
        #expect(try !contender.tryAcquire())

        let finished = DispatchSemaphore(value: 0)
        let registered = LockedFlag()
        let readyDescriptor = ready[1]
        Thread.detachNewThread {
            registered.set(AgentRestoreLaunchLease.runExitWatcher(
                processID: agent.pid, leaseDescriptor: watcherLease, readyDescriptor: readyDescriptor
            ))
            finished.signal()
        }
        var byte: UInt8 = 0
        #expect(read(ready[0], &byte, 1) == 1 && byte == 1)
        close(ready[0])
        #expect(try !contender.tryAcquire())

        close(agent.release)
        var status: Int32 = 0
        #expect(waitpid(agent.pid, &status, 0) == agent.pid)
        #expect(status == 0)
        finished.wait()
        #expect(registered.value)
        #expect(try contender.tryAcquire())
    }

    @Test("Transfer spawns an isolated watcher, and the launched process never inherits the lease")
    func transferScopesLeaseAwayFromLaunchedProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID().uuidString
        let lease = try AgentRestoreLaunchLease(directory: directory, account: "/codex", sessionID: session)
        #expect(try lease.tryAcquire())
        let path = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let agent = try spawnAgentStandIn(leasePath: path.path)

        // A stand-in watcher executable with the same fd 3/4 contract as
        // `runExitWatcher`, watching the agent stand-in instead of this runner.
        let watcher = """
        import os, select, sys
        kq = select.kqueue()
        kq.control([select.kevent(int(sys.argv[1]), select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT, select.KQ_NOTE_EXIT)], 0)
        os.write(4, b'\\x01'); os.close(4)
        kq.control(None, 1)
        """
        try lease.transferToExitWatcher(
            executablePath: "/usr/bin/python3",
            arguments: ["/usr/bin/python3", "-c", watcher, String(agent.pid)]
        )
        // Exec closes the launching process's close-on-exec descriptor.
        lease.release()
        let contender = try AgentRestoreLaunchLease(directory: directory, account: "/codex", sessionID: session)
        #expect(try !contender.tryAcquire())

        close(agent.release)
        var status: Int32 = 0
        #expect(waitpid(agent.pid, &status, 0) == agent.pid)
        #expect(status == 0, "the launched process inherited the lease descriptor")
        try contender.acquireAfterOwnerExit()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
