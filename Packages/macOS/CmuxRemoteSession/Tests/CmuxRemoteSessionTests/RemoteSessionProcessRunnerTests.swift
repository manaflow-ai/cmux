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
        let marker = try ProcessMarkerFixture()
        let runner = RemoteSessionProcessRunner(
            stdinWriter: MarkerGatedFailingRemoteProcessStdinWriter(
                readyFIFOURL: marker.readyFIFOURL,
                exitFIFOURL: marker.exitFIFOURL,
                markerURL: marker.markerURL,
                gate: .launched
            )
        )

        #expect {
            try runner.run(
                RemoteProcessRequest(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo $$ > \"$CMUX_TEST_PROCESS_READY\"; exec /bin/sleep 30",
                    ],
                    environment: [
                        "CMUX_TEST_PROCESS_READY": marker.readyFIFOURL.path,
                    ],
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
        #expect(try marker.recordedProcessHasExited())
    }

    @Test("A stdin write error wins when the child ignores termination")
    func stdinWriteErrorWinsWhenChildIgnoresTermination() async throws {
        let marker = try ProcessMarkerFixture()
        let runner = RemoteSessionProcessRunner(
            stdinWriter: MarkerGatedFailingRemoteProcessStdinWriter(
                readyFIFOURL: marker.readyFIFOURL,
                exitFIFOURL: marker.exitFIFOURL,
                markerURL: marker.markerURL,
                gate: .launched
            )
        )

        let outcome = try #require(await runProcess(
            runner,
            request: RemoteProcessRequest(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; echo $$ > \"$CMUX_TEST_PROCESS_READY\"; exec /bin/sleep 30",
                ],
                environment: [
                    "CMUX_TEST_PROCESS_READY": marker.readyFIFOURL.path,
                ],
                stdin: Data("payload".utf8),
                timeout: 10
            ),
            completingWithin: 4
        ))

        guard case .failure(let error) = outcome else {
            Issue.record("Expected the stdin write to fail")
            return
        }
        let nsError = error as NSError
        let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? POSIXError
        #expect(nsError.domain == "cmux.remote.process")
        #expect(nsError.code == 3)
        #expect(underlyingError?.code == .EIO)
    }

    @Test("A late stdin write error wins over an earlier child exit")
    func lateStdinWriteErrorWinsOverChildExit() throws {
        let marker = try ProcessMarkerFixture()
        let runner = RemoteSessionProcessRunner(
            stdinWriter: MarkerGatedFailingRemoteProcessStdinWriter(
                readyFIFOURL: marker.readyFIFOURL,
                exitFIFOURL: marker.exitFIFOURL,
                markerURL: marker.markerURL,
                gate: .exited
            )
        )

        #expect {
            try runner.run(
                RemoteProcessRequest(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo $$ > \"$CMUX_TEST_PROCESS_READY\"; exec 3>\"$CMUX_TEST_PROCESS_EXIT\"; exit 0",
                    ],
                    environment: [
                        "CMUX_TEST_PROCESS_READY": marker.readyFIFOURL.path,
                        "CMUX_TEST_PROCESS_EXIT": marker.exitFIFOURL.path,
                    ],
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
    func unreadStdinCannotDelayProcessTimeout() async throws {
        let runner = RemoteSessionProcessRunner()
        let outcome = try #require(await runProcess(
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
    func inheritedUnreadStdinCannotOutliveProcessTimeout() async throws {
        let runner = RemoteSessionProcessRunner()
        let outcome = try #require(await runProcess(
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

    private func runProcess(
        _ runner: RemoteSessionProcessRunner,
        request: RemoteProcessRequest,
        completingWithin timeout: TimeInterval
    ) async -> Result<RemoteCommandResult, any Error>? {
        await withTaskGroup(
            of: ProcessRunEvent.self,
            returning: Result<RemoteCommandResult, any Error>?.self
        ) { group in
            group.addTask {
                .completed(Result {
                    try runner.run(request, operation: nil)
                })
            }
            group.addTask {
                try? await Task<Never, Never>.sleep(for: .seconds(timeout))
                return .deadline
            }

            guard let firstEvent = await group.next() else {
                return nil
            }
            group.cancelAll()
            switch firstEvent {
            case .completed(let result):
                return result
            case .deadline:
                // Structured concurrency reaps the test-owned blocking task
                // before leaving this scope and starting another subprocess.
                return nil
            }
        }
    }
}
}
