import Darwin
import Foundation
import Testing
@testable import CmuxRemoteSession

// The blocking process runner behind the coordinator's ssh/scp execs.
// The capture-survives-teardown case is retargeted from the app's
// testARunProcessCaptureSurvivesPipeReadHandleTeardown (assertions
// unchanged); the launch-failure and timeout cases pin the legacy
// `cmux.remote.process` error codes 1 and 2.
//
// Every test here spawns a real `Process` with `Pipe`s and raw-reads the pipe
// file descriptors. Under Swift Testing's default parallel execution, a sibling
// test closing a `FileHandle` lets the OS recycle that fd number, so a background
// reader in another test can read a foreign stream (cross-wired stdout/stderr/stdin).
// This suite therefore lives under the shared serialized subprocess parent,
// matching production's strictly serial runner use per coordinator.
extension RemoteSubprocessTests {
@Suite("RemoteSessionProcessRunner")
struct RemoteSessionProcessRunnerTests {
    @Test("Capture survives the pipe read handles being torn down mid-run")
    func captureSurvivesPipeReadHandleTeardown() throws {
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

    @Test("A child closing stdin before a large write does not abort the runner")
    func childClosingStdinDoesNotAbortRunner() throws {
        let runner = RemoteSessionProcessRunner()
        let result = try runner.run(
            RemoteProcessRequest(
                executable: "/usr/bin/true",
                arguments: [],
                stdin: Data(repeating: 0x41, count: 1_048_576),
                timeout: 5
            ),
            operation: nil
        )

        #expect(result.status == 0)
    }

    @Test("An unexpected stdin write error terminates the child and keeps the pinned runner error")
    func unexpectedStdinWriteErrorTerminatesChildAndKeepsPinnedRunnerError() throws {
        let markerURL = processMarkerURL()
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let runner = RemoteSessionProcessRunner(
            stdinWriter: MarkerGatedFailingRemoteProcessStdinWriter(
                markerURL: markerURL,
                gate: .launched
            )
        )

        #expect {
            try runner.run(
                RemoteProcessRequest(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo $$ > \"$CMUX_TEST_PROCESS_MARKER\"; exec /bin/sleep 30",
                    ],
                    environment: ["CMUX_TEST_PROCESS_MARKER": markerURL.path],
                    stdin: Data("payload".utf8),
                    timeout: 5
                ),
                operation: nil
            )
        } throws: { error in
            let nsError = error as NSError
            let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? POSIXError
            return nsError.domain == "cmux.remote.process"
                && nsError.code == 3
                && nsError.localizedDescription.hasPrefix("Failed to write stdin for sh:")
                && underlyingError?.code == .EIO
        }
        let processIdentifier = try recordedProcessIdentifier(at: markerURL)
        #expect(waitForProcessExit(processIdentifier, timeout: 2))
    }

    @Test("A late stdin write error wins over an earlier child exit")
    func lateStdinWriteErrorWinsOverChildExit() throws {
        let markerURL = processMarkerURL()
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let runner = RemoteSessionProcessRunner(
            stdinWriter: MarkerGatedFailingRemoteProcessStdinWriter(
                markerURL: markerURL,
                gate: .exited
            )
        )

        #expect {
            try runner.run(
                RemoteProcessRequest(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo $$ > \"$CMUX_TEST_PROCESS_MARKER\"; exit 0",
                    ],
                    environment: ["CMUX_TEST_PROCESS_MARKER": markerURL.path],
                    stdin: Data("payload".utf8),
                    timeout: 5
                ),
                operation: nil
            )
        } throws: { error in
            let nsError = error as NSError
            let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? POSIXError
            return nsError.domain == "cmux.remote.process"
                && nsError.code == 3
                && underlyingError?.code == .EIO
        }
    }

    @Test("A child retaining unread stdin cannot delay the process timeout")
    func unreadStdinCannotDelayProcessTimeout() throws {
        let runner = RemoteSessionProcessRunner()
        let outcome = try #require(runProcess(
            runner,
            request: RemoteProcessRequest(
                executable: "/bin/sleep",
                arguments: ["5"],
                stdin: Data(repeating: 0x41, count: 1_048_576),
                timeout: 1
            ),
            completingWithin: 4
        ))

        switch outcome {
        case .success:
            Issue.record("Expected the unread stdin request to time out")
        case .failure(let error):
            let nsError = error as NSError
            #expect(
                nsError.domain == "cmux.remote.process"
                && nsError.code == 2
                && nsError.localizedDescription == "sleep timed out after 1s"
            )
        }
    }

    @Test("A descendant retaining unread stdin cannot outlive the process timeout")
    func inheritedUnreadStdinCannotOutliveProcessTimeout() throws {
        let runner = RemoteSessionProcessRunner()
        let outcome = try #require(runProcess(
            runner,
            request: RemoteProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 5 <&0 &"],
                stdin: Data(repeating: 0x41, count: 1_048_576),
                timeout: 1
            ),
            completingWithin: 4
        ))

        switch outcome {
        case .success:
            Issue.record("Expected the inherited stdin request to time out")
        case .failure(let error):
            let nsError = error as NSError
            #expect(
                nsError.domain == "cmux.remote.process"
                && nsError.code == 2
                && nsError.localizedDescription == "sh timed out after 1s"
            )
        }
    }

    @Test("Streams a local file through stdin")
    func streamsFileStdin() throws {
        let fileManager = FileManager.default
        let fileURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-process-stdin-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data("hello-file-stdin".utf8).write(to: fileURL)
        defer { try? fileManager.removeItem(at: fileURL) }

        let runner = RemoteSessionProcessRunner()
        let result = try runner.run(
            RemoteProcessRequest(
                executable: "/bin/cat",
                arguments: [],
                stdinFile: fileURL,
                timeout: 5
            ),
            operation: nil
        )

        #expect(result.status == 0)
        #expect(result.stdout == "hello-file-stdin")
    }

    @Test("Launch failure throws the pinned cmux.remote.process code 1")
    func launchFailurePinsErrorCode() {
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
}

private func processMarkerURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "cmux-remote-process-\(UUID().uuidString).pid",
        isDirectory: false
    )
}

private func recordedProcessIdentifier(at markerURL: URL) throws -> pid_t {
    let contents = try String(contentsOf: markerURL, encoding: .utf8)
    return try #require(
        pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    )
}

private func waitForProcessExit(_ processIdentifier: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = DispatchTime.now() + timeout
    repeat {
        errno = 0
        if kill(processIdentifier, 0) == -1, errno == ESRCH {
            return true
        }
        Thread.sleep(forTimeInterval: 0.01)
    } while DispatchTime.now() < deadline
    return false
}

private final class RemoteProcessRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<RemoteCommandResult, any Error>?

    var result: Result<RemoteCommandResult, any Error>? {
        lock.withLock { storedResult }
    }

    func record(_ result: Result<RemoteCommandResult, any Error>) {
        lock.withLock {
            storedResult = result
        }
    }
}

private func runProcess(
    _ runner: RemoteSessionProcessRunner,
    request: RemoteProcessRequest,
    completingWithin timeout: TimeInterval
) -> Result<RemoteCommandResult, any Error>? {
    let recorder = RemoteProcessRunRecorder()
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        recorder.record(Result {
            try runner.run(request, operation: nil)
        })
        completed.signal()
    }

    guard completed.wait(timeout: .now() + timeout) == .success else {
        // The fixture exits after five seconds, so reap the test-owned work
        // before returning a failure and starting another subprocess test.
        completed.wait()
        return nil
    }
    return recorder.result
}
