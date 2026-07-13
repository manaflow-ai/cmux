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

    @Test func outputLimitClosesSiblingReaderHeldByDescendant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-command-output-descendant-\(UUID().uuidString)",
            isDirectory: true
        )
        let resultFile = root.appendingPathComponent("result.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = FileWatcher(path: resultFile.path)
        let result = await runner.run(
            directory: root.path,
            executable: "perl",
            arguments: [
                "-e",
                "my $fifo = shift; pipe(my $ready_r, my $ready_w) or die $!; my $pid = fork(); if ($pid == 0) { close $ready_r; close STDOUT; $SIG{TERM} = 'IGNORE'; $SIG{HUP} = 'IGNORE'; $SIG{PIPE} = 'IGNORE'; syswrite($ready_w, '1'); close $ready_w; while (defined syswrite(STDERR, 'x' x 65536)) {} open my $out, '>', $fifo or die $!; print $out 'closed'; exit 0; } close $ready_w; sysread($ready_r, my $ready, 1); close $ready_r; while (1) { print STDOUT 'output\\n'; }",
                resultFile.path,
            ],
            maximumOutputBytes: 1_024,
            timeout: 5
        )
        for await _ in watcher.events {
            let size = try? resultFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if (size ?? 0) > 0 { break }
        }
        await watcher.stop()
        let observedPipeState = try String(contentsOf: resultFile, encoding: .utf8)

        #expect(result.outputLimitExceeded == true)
        #expect(observedPipeState == "closed")
    }
}
