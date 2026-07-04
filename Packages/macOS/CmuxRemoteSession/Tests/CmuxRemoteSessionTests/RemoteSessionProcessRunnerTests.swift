import Foundation
import Testing
@testable import CmuxRemoteSession

// The blocking process runner behind the coordinator's ssh/scp execs.
// The capture-survives-teardown case is retargeted from the app's
// testARunProcessCaptureSurvivesPipeReadHandleTeardown (assertions
// unchanged); the launch-failure and timeout cases pin the legacy
// `cmux.remote.process` error codes 1 and 2.
//
// `.serialized`: every test here spawns a real `Process` with `Pipe`s and
// raw-reads the pipe file descriptors. Under Swift Testing's default parallel
// execution, a sibling test closing a `FileHandle` lets the OS recycle that fd
// number, so a background reader in another test can read a foreign stream
// (cross-wired stdout/stderr/stdin). These tests share the process-global fd
// table and are inherently not parallel-safe against each other. Serializing
// also matches production, where the runner executes strictly serially per
// coordinator, so this race window does not exist in the real app.
@Suite("RemoteSessionProcessRunner", .serialized)
struct RemoteSessionProcessRunnerTests {
    @Test("Capture survives the pipe read handles being torn down mid-run")
    func captureSurvivesPipeReadHandleTeardown() throws {
        // Serialize against the platform-probe suite; see ``remoteSubprocessTestLock``.
        remoteSubprocessTestLock.lock()
        defer { remoteSubprocessTestLock.unlock() }
        let didCloseReadHandles = DispatchSemaphore(value: 0)
        let runner = RemoteSessionProcessRunner(readHandlesDidInstall: { stdoutHandle, stderrHandle in
            try? stdoutHandle.close()
            try? stderrHandle.close()
            didCloseReadHandles.signal()
            return true
        })

        let result = try runner.run(
            RemoteProcessRequest(executable: "/usr/bin/true", arguments: [], timeout: 2),
            operation: nil
        )

        #expect(didCloseReadHandles.wait(timeout: .now() + 2) == .success)
        #expect(result.status == 0)
        #expect(result.stdout == "")
        #expect(result.stderr == "")
    }

    @Test("Captures stdout, stderr, and the exit status")
    func capturesOutputAndStatus() throws {
        remoteSubprocessTestLock.lock()
        defer { remoteSubprocessTestLock.unlock() }
        let runner = RemoteSessionProcessRunner()
        let result = try runner.run(
            RemoteProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", "printf out; printf err 1>&2; exit 3"],
                timeout: 5
            ),
            operation: nil
        )
        #expect(result.status == 3)
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
    }

    @Test("Delivers stdin and closes the write end")
    func deliversStdin() throws {
        remoteSubprocessTestLock.lock()
        defer { remoteSubprocessTestLock.unlock() }
        let runner = RemoteSessionProcessRunner()
        let result = try runner.run(
            RemoteProcessRequest(
                executable: "/bin/cat",
                arguments: [],
                stdin: Data("hello-stdin".utf8),
                timeout: 5
            ),
            operation: nil
        )
        #expect(result.status == 0)
        #expect(result.stdout == "hello-stdin")
    }

    @Test("Streams a large stdin payload through to stdout without truncation")
    func deliversLargeStdin() throws {
        remoteSubprocessTestLock.lock()
        defer { remoteSubprocessTestLock.unlock() }
        let runner = RemoteSessionProcessRunner()
        // Far larger than the OS pipe buffer (~64 KiB) so the writer must loop
        // over backpressured partial writes while the stdout reader drains
        // concurrently — the path the cmuxd-remote binary upload now exercises
        // by piping the daemon over ssh stdin (issue #6207).
        let payload = String(repeating: "cmux-remote-daemon-", count: 60_000)
        let result = try runner.run(
            RemoteProcessRequest(
                executable: "/bin/cat",
                arguments: [],
                stdin: Data(payload.utf8),
                timeout: 20
            ),
            operation: nil
        )
        #expect(result.status == 0)
        #expect(result.stdout == payload)
    }

    @Test("Launch failure throws the pinned cmux.remote.process code 1")
    func launchFailurePinsErrorCode() {
        remoteSubprocessTestLock.lock()
        defer { remoteSubprocessTestLock.unlock() }
        let runner = RemoteSessionProcessRunner()
        #expect {
            try runner.run(
                RemoteProcessRequest(
                    executable: "/nonexistent/cmux-no-such-binary",
                    arguments: [],
                    timeout: 2
                ),
                operation: nil
            )
        } throws: { error in
            let nsError = error as NSError
            return nsError.domain == "cmux.remote.process"
                && nsError.code == 1
                && nsError.localizedDescription.hasPrefix("Failed to launch cmux-no-such-binary:")
        }
    }

    @Test("Timeout terminates the process and throws the pinned code 2")
    func timeoutPinsErrorCode() {
        remoteSubprocessTestLock.lock()
        defer { remoteSubprocessTestLock.unlock() }
        let runner = RemoteSessionProcessRunner()
        #expect {
            try runner.run(
                RemoteProcessRequest(
                    executable: "/bin/sh",
                    arguments: ["-c", "sleep 30"],
                    timeout: 1
                ),
                operation: nil
            )
        } throws: { error in
            let nsError = error as NSError
            return nsError.domain == "cmux.remote.process"
                && nsError.code == 2
                && nsError.localizedDescription == "sh timed out after 1s"
        }
    }
}
