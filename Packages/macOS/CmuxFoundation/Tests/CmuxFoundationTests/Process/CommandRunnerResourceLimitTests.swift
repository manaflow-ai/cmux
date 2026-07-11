import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct CommandRunnerResourceLimitTests {
    private let runner = CommandRunner()
    private let tempDir = FileManager.default.temporaryDirectory.path

    @Test func stopsWritingStandardInputWhenImmediateChildExits() async throws {
        let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)

        let result = await runner.run(
            directory: tempDir,
            executable: "sh",
            arguments: [
                "-c",
                "exec 3<&0; (sleep 0.5; wc -c <&3) & exit 0",
            ],
            standardInput: payload,
            timeout: 10
        )

        let writtenByteCount = try #require(
            Int(result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        )
        #expect(result.executionError == nil)
        #expect(result.timedOut == false)
        #expect(result.exitStatus == 0)
        #expect(writtenByteCount < payload.count)
    }

    @Test func stopsAndBoundsCaptureWhenOutputLimitIsExceeded() async {
        let maximumOutputBytes = 1_024

        let result = await runner.run(
            directory: tempDir,
            executable: "sh",
            arguments: ["-c", "yes output"],
            maximumOutputBytes: maximumOutputBytes,
            timeout: 10
        )

        #expect(result.outputLimitExceeded == true)
        #expect(result.timedOut == false)
        #expect(result.executionError == nil)
        #expect((result.stdout?.utf8.count ?? 0) <= maximumOutputBytes)
        #expect((result.stderr?.utf8.count ?? 0) <= maximumOutputBytes)
    }
}
