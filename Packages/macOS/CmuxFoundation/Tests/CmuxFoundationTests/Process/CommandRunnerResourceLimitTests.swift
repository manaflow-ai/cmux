import Darwin
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

    @Test(.timeLimit(.minutes(1)))
    func outputLimitDoesNotWaitForSiblingReaderHeldByDescendant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-command-output-descendant-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await runner.run(
            directory: root.path,
            executable: "perl",
            arguments: [
                "-e",
                "pipe(my $ready_r, my $ready_w) or die $!; my $pid = fork(); if ($pid == 0) { close $ready_r; close STDOUT; $SIG{TERM} = 'IGNORE'; $SIG{HUP} = 'IGNORE'; $SIG{PIPE} = 'IGNORE'; syswrite($ready_w, '1'); close $ready_w; while (defined syswrite(STDERR, 'x' x 65536)) {} exit 0; } close $ready_w; sysread($ready_r, my $ready, 1); close $ready_r; while (1) { print STDOUT 'output\\n'; }",
            ],
            maximumOutputBytes: 1_024,
            timeout: 5
        )

        #expect(result.outputLimitExceeded == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationTerminatesProcessBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-command-cancellation-\(UUID().uuidString)",
            isDirectory: true
        )
        let pidFile = root.appendingPathComponent("pid.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = Task {
            await runner.run(
                directory: root.path,
                executable: "sh",
                arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do sleep 1; done", "sh", pidFile.path],
                timeout: nil
            )
        }
        for _ in 0..<500 {
            if (try? pidFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(String(contentsOf: pidFile, encoding: .utf8).first)

        let cancellationStarted = ContinuousClock.now
        command.cancel()
        let result = await command.value
        let cancellationDuration = cancellationStarted.duration(to: .now)
        let pid = try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))

        #expect(result.executionError == "Command cancelled.")
        #expect(result.cancellationCleanupSucceeded == true)
        #expect(cancellationDuration < .seconds(5))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test(.timeLimit(.minutes(1)))
    func commandRunnerReportsLostOwnershipAfterImmediateLeaderExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-command-orphan-cancellation-\(UUID().uuidString)",
            isDirectory: true
        )
        let pidFile = root.appendingPathComponent("descendant-pid.txt")
        let helperSource = root.appendingPathComponent("immediate-exit.c")
        let helperExecutable = root.appendingPathComponent("immediate-exit")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #include <signal.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>

        int main(int argc, char **argv) {
            if (argc != 2) return 2;
            pid_t child = fork();
            if (child < 0) return 3;
            if (child == 0) {
                signal(SIGTERM, SIG_IGN);
                signal(SIGHUP, SIG_IGN);
                FILE *file = fopen(argv[1], "w");
                if (file == NULL) _exit(4);
                fprintf(file, "%d\\n", getpid());
                fclose(file);
                for (;;) pause();
            }
            _exit(0);
        }
        """.write(to: helperSource, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [helperSource.path, "-o", helperExecutable.path]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)

        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["30"]
        try sentinel.run()
        let sentinelGroupID = getpgid(sentinel.processIdentifier)
        #expect(sentinelGroupID == sentinel.processIdentifier)
        defer {
            if sentinel.isRunning {
                _ = kill(sentinel.processIdentifier, SIGKILL)
                sentinel.waitUntilExit()
            }
        }

        let runner = CommandRunner(
            standardInputWriterFactory: CommandStandardInputWriter.init,
            processGroupResolver: { process in
                process.waitUntilExit()
                return sentinelGroupID
            }
        )
        let command = Task {
            await runner.run(
                directory: root.path,
                executable: helperExecutable.path,
                arguments: [pidFile.path],
                timeout: nil
            )
        }
        for _ in 0..<500 {
            if (try? pidFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer {
            if kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
            }
        }

        command.cancel()
        let result = await command.value

        #expect(result.executionError == "Command cancelled, but its process tree did not exit.")
        #expect(result.cancellationCleanupSucceeded == false)
        #expect(kill(pid, 0) == 0)
        #expect(kill(sentinel.processIdentifier, 0) == 0)
    }

    @Test func processTreeEscalationDoesNotDelayOrResignalGroup() async {
        let signalRecorder = ProcessSignalRecorder()
        let process = Process()

        let processTreeExited = await withCheckedContinuation { continuation in
            CommandProcessTreeTerminator.terminate(
                process,
                processGroupID: 42,
                completionWaitSeconds: 1,
                signalProcessGroup: signalRecorder.record,
                ownsProcessGroup: { _, _ in true },
                processGroupExists: { _ in false },
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(processTreeExited)
        #expect(signalRecorder.snapshot() == [SIGKILL])
    }

    @Test func processTreeExitPollingHasFiniteFailureResult() async {
        let process = Process()

        let processTreeExited = await withCheckedContinuation { continuation in
            CommandProcessTreeTerminator.terminate(
                process,
                processGroupID: 42,
                completionWaitSeconds: 0.02,
                signalProcessGroup: { _, _ in },
                ownsProcessGroup: { _, _ in true },
                processGroupExists: { _ in true },
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(!processTreeExited)
    }
}
