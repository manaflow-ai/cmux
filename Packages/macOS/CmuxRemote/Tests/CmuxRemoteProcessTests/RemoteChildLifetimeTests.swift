@testable import CmuxRemoteHost
import CmuxRemoteWire
import Darwin
import Foundation
import Testing
import os

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
        lifetime.watch(child) { status in
            if status >= 0 { lifetime.reaped(child) }
        }
        close(child.stdin)
        #expect(await lifetime.waitUntilEmpty(timeout: .seconds(5)))
    }

    @Test(.timeLimit(.minutes(1))) func stopOwnedChildrenUsesTheGatedReaper() async throws {
        let lifetime = RemoteChildLifetime()
        let child = try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        defer { close(child.stdout) }
        lifetime.watch(child) { status in
            if status >= 0 { lifetime.reaped(child) }
        }
        lifetime.freeze()
        lifetime.stopOwnedChildren()
        #expect(await lifetime.waitUntilEmpty(timeout: .seconds(5)))
    }

    @Test(.timeLimit(.minutes(1))) func stopReachesAChildSpawnedFromAThreadThatBlocksSigterm() async throws {
        let lifetime = RemoteChildLifetime()
        // A child inherits its spawning thread's signal mask; this thread blocks SIGTERM.
        let child = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChildProcess, any Error>) in
            let thread = Thread {
                var blocked = sigset_t()
                sigemptyset(&blocked)
                sigaddset(&blocked, SIGTERM)
                pthread_sigmask(SIG_BLOCK, &blocked, nil)
                continuation.resume(with: Result {
                    try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
                })
            }
            thread.start()
        }
        defer { close(child.stdin); close(child.stdout) }
        lifetime.watch(child) { status in
            if status >= 0 { lifetime.reaped(child) }
        }
        lifetime.freeze()
        lifetime.stopOwnedChildren()
        // stdin stays open: only the SIGTERM can end it.
        #expect(await lifetime.waitUntilEmpty(timeout: .seconds(5)))
    }

    @Test(.timeLimit(.minutes(1))) func duplicateReapCannotRemoveAnotherTrackedChild() async throws {
        let lifetime = RemoteChildLifetime()
        let old = try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        let current = try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        defer { close(old.stdout); close(current.stdout) }
        lifetime.freeze()
        lifetime.watch(old) { status in
            if status >= 0 { lifetime.reaped(old) }
        }
        close(old.stdin)
        // Duplicate callbacks for one spawn cannot remove a different tracked child.
        lifetime.reaped(old)
        lifetime.reaped(old)
        #expect(await lifetime.waitUntilEmpty(timeout: .zero) == false)
        lifetime.watch(current) { status in
            if status >= 0 { lifetime.reaped(current) }
        }
        close(current.stdin)
        #expect(await lifetime.waitUntilEmpty(timeout: .seconds(5)))
    }

    @Test(.timeLimit(.minutes(1))) func shutdownKillsAStampedChildThatOutlivesTheTermDeadline() async throws {
        let lifetime = RemoteChildLifetime()
        let child = try lifetime.spawn(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; echo ready; read line"],
                                       environment: [:], logPath: "/dev/null")
        defer { close(child.stdin); close(child.stdout) }
        lifetime.watch(child) { status in
            if status >= 0 { lifetime.reaped(child) }
        }
        // The trap is installed once the child says so.
        var ready = [UInt8](repeating: 0, count: 6)
        #expect(read(child.stdout, &ready, ready.count) > 0)
        lifetime.freeze()
        lifetime.stopOwnedChildren()
        #expect(await lifetime.waitUntilEmpty(timeout: .milliseconds(300)) == false)
        #expect(await lifetime.terminate(grace: .milliseconds(100), kill: .seconds(5)))
    }

    @Test(.timeLimit(.minutes(1))) func oneReaperThreadServesEveryTrackedChild() async throws {
        let lifetime = RemoteChildLifetime()
        let threads = OSAllocatedUnfairLock(initialState: [String]())
        var children: [ChildProcess] = []
        for _ in 0..<8 {
            children.append(try lifetime.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null"))
        }
        defer { children.forEach { close($0.stdout) } }
        for child in children {
            lifetime.watch(child) { status in
                threads.withLock { $0.append(Thread.current.name ?? "") }
                if status >= 0 { lifetime.reaped(child) }
            }
        }
        children.forEach { close($0.stdin) }
        #expect(await lifetime.waitUntilEmpty(timeout: .seconds(5)))
        let seen = threads.withLock { $0 }
        // Waiting costs no thread per child and no periodic wakeup: one kernel exit reaper.
        #expect(seen.count == children.count)
        #expect(Set(seen) == [RemoteChildLifetime.reaperName])
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
