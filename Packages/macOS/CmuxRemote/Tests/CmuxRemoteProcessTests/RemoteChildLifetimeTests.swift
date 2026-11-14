@testable import CmuxRemoteHost
import CmuxRemoteWire
import Darwin
import Foundation
import Testing

@Suite struct RemoteChildLifetimeTests {
    @Test func freezeRefusesLateSpawnAndCannotReopen() throws {
        let lifetime = RemoteChildLifetime()
        #expect(lifetime.claimIdle())
        lifetime.reopenAfterPrepare()
        #expect(lifetime.accepting)
        lifetime.freeze()
        lifetime.reopenAfterPrepare()
        #expect(!lifetime.accepting && !lifetime.claimIdle())
        #expect(throws: (any Error).self) {
            try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        }
    }

    @Test(.timeLimit(.minutes(1))) func quiescenceNeedsReapingNotJustClosedAdmission() async throws {
        let lifetime = RemoteChildLifetime()
        let child = try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        defer { close(child.stdout) }
        #expect(!lifetime.claimIdle())
        lifetime.freeze()
        #expect(await lifetime.waitUntilEmpty(timeout: .zero) == false)
        ChildProcess.watch(child.pid, name: "capture-lease-test-reap") { status in
            if status >= 0 { lifetime.reaped(child) }
        }
        close(child.stdin)
        #expect(await lifetime.waitUntilEmpty(timeout: .seconds(5)))
    }

    @Test(.timeLimit(.minutes(1))) func duplicateReapCannotRemoveAnotherTrackedChild() async throws {
        let lifetime = RemoteChildLifetime()
        let old = try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        let current = try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        defer { close(old.stdout); close(current.stdout) }
        lifetime.freeze()
        ChildProcess.watch(old.pid, name: "capture-old-generation") { status in
            if status >= 0 { lifetime.reaped(old) }
        }
        close(old.stdin)
        // Duplicate callbacks for one spawn cannot remove a different tracked child.
        lifetime.reaped(old)
        lifetime.reaped(old)
        #expect(await lifetime.waitUntilEmpty(timeout: .zero) == false)
        ChildProcess.watch(current.pid, name: "capture-current-generation") { status in
            if status >= 0 { lifetime.reaped(current) }
        }
        close(current.stdin)
        #expect(await lifetime.waitUntilEmpty(timeout: .seconds(5)))
    }

    @Test(.timeLimit(.minutes(1))) func failedWaitpidIsNotAnExitReceipt() async {
        let pair = AsyncStream<Int32>.makeStream()
        // This process is not its own child: ECHILD must not look like exit status zero.
        ChildProcess.watch(getpid(), name: "capture-lease-test-no-child") { status in
            pair.continuation.yield(status); pair.continuation.finish()
        }
        var iterator = pair.stream.makeAsyncIterator()
        #expect(await iterator.next() == -1)
    }
}
