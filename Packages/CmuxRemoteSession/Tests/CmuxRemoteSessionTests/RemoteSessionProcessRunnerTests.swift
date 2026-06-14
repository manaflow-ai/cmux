import Foundation
import Testing
@testable import CmuxRemoteSession

// Process/pipe tests share one serialized suite because they touch the
// process-global fd table. Serializing each child group separately is not
// enough: Swift Testing can still run sibling suites in parallel.
@Suite("Remote process pipes", .serialized)
struct RemoteProcessPipeTests {}

// The blocking process runner behind the coordinator's ssh/scp execs. The
// capture-survives-teardown case is retargeted from the app's
// testARunProcessCaptureSurvivesPipeReadHandleTeardown (assertions unchanged);
// the launch-failure and timeout cases pin the legacy `cmux.remote.process`
// error codes 1 and 2.
extension RemoteProcessPipeTests {
    @Test("Capture survives the pipe read handles being torn down mid-run")
    func captureSurvivesPipeReadHandleTeardown() throws {
        let didCloseReadHandles = DispatchSemaphore(value: 0)
        let runner = RemoteSessionProcessRunner(readHandlesDidInstall: { stdoutHandle, stderrHandle in
            try? stdoutHandle.close()
            try? stderrHandle.close()
            didCloseReadHandles.signal()
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
