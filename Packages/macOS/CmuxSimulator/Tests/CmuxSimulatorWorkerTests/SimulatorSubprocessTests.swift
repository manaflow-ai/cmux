import Darwin
import Foundation
import Testing
@testable import CmuxSimulator
@testable import CmuxSimulatorWorker

@Suite("Simulator subprocess cancellation")
struct SimulatorSubprocessTests {
    @Test("Cancellation escalates from TERM to bounded KILL")
    func forceKillsIgnoringProcess() async throws {
        let runner = SimulatorSubprocessRunner(terminationGrace: .milliseconds(50))
        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"]
            )
        }
        try await ContinuousClock().sleep(for: .milliseconds(100))
        task.cancel()

        let result = await withTaskGroup(of: Result<SimulatorSubprocessResult, Error>?.self) { group in
            group.addTask { await task.result }
            group.addTask {
                try? await ContinuousClock().sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard case let .success(processResult) = result else {
            Issue.record("The TERM-ignoring subprocess did not exit after bounded KILL")
            return
        }
        #expect(processResult.status == SIGKILL)
    }

    @Test("Output stays bounded while both pipes continue draining")
    func boundedOutput() async throws {
        let runner = SimulatorSubprocessRunner(
            standardOutputLimit: 1_024,
            standardErrorLimit: 512
        )
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "yes 0123456789 | head -c 65536; yes abcdef | head -c 65536 >&2",
            ]
        )

        #expect(result.status == 0)
        #expect(result.standardOutput.utf8.count == 1_024)
        #expect(result.standardError.utf8.count == 512)
        #expect(result.outputWasTruncated)
        #expect(result.errorWasTruncated)
    }

    @Test("Fast normal exits preserve buffered stdout and stderr")
    func normalExitDrainsBufferedOutput() async throws {
        let runner = SimulatorSubprocessRunner()
        let stdout = String(repeating: "stdout-payload-", count: 512)
        let stderr = String(repeating: "stderr-payload-", count: 512)

        for _ in 0..<32 {
            let result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf %s \"$1\"; printf %s \"$2\" >&2", "cmux", stdout, stderr]
            )
            #expect(result.status == 0)
            #expect(result.standardOutput == stdout)
            #expect(result.standardError == stderr)
            #expect(!result.outputWasTruncated)
            #expect(!result.errorWasTruncated)
        }
    }

    @Test("Inherent timeout escalates a TERM-ignoring child to KILL")
    func inherentTimeout() async throws {
        let sleeper = FastEscalationSubprocessSleeper()
        let runner = SimulatorSubprocessRunner(
            terminationGrace: .seconds(30),
            timeout: .milliseconds(50),
            sleeper: sleeper
        )
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"]
        )

        #expect(result.timedOut)
        #expect(result.status == SIGKILL)
        #expect(await sleeper.callCount >= 2)
    }

    @Test("Cancelling a worker command terminates its command group")
    func cancellationTerminatesSubprocessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-subprocess-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = SimulatorSubprocessRunner(terminationGrace: .milliseconds(50))
        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-MPOSIX",
                    "-e",
                    #"""
                my $leader = $$;
                my $leader_group = POSIX::getpgrp();
                my $child = fork();
                defined($child) or die "fork: $!";
                if ($child == 0) {
                    open(my $marker, '>', $ARGV[0]) or die "marker: $!";
                    print $marker "$leader $leader_group $$ ", POSIX::getpgrp(), "\n";
                    close($marker);
                    while (1) { sleep 1; }
                }
                while (1) { sleep 1; }
                """#,
                    marker.path,
                ]
            )
        }
        let identifiers = try await Self.requireProcessTreeMarker(marker)
        #expect(identifiers.leaderGroup == identifiers.childGroup)
        #expect(identifiers.leaderGroup != getpgrp())
        #expect(identifiers.leaderGroup != identifiers.leader)
        task.cancel()
        _ = try await task.value
        await Self.expectProcessExited(identifiers.child)
    }

    @Test("Normal leader exit terminates command descendants")
    func normalExitTerminatesSubprocessGroup() async throws {
        let runner = SimulatorSubprocessRunner()
        for _ in 0..<32 {
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-subprocess-normal-descendant-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }
            let result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-MPOSIX",
                    "-e",
                    #"""
                my $child = fork();
                defined($child) or die "fork: $!";
                if ($child == 0) {
                    open(STDIN, '<', '/dev/null') or die "stdin: $!";
                    open(STDOUT, '>', '/dev/null') or die "stdout: $!";
                    open(STDERR, '>', '/dev/null') or die "stderr: $!";
                    while (1) { sleep 1; }
                }
                open(my $marker, '>', $ARGV[0]) or die "marker: $!";
                print $marker "$$ ", POSIX::getpgrp(), " $child\n";
                close($marker);
                exit 0;
                """#,
                    marker.path,
                ]
            )
            let identifiers = try await Self.requireNormalExitMarker(marker)

            #expect(result.status == 0)
            #expect(identifiers.leaderGroup != getpgrp())
            #expect(identifiers.leaderGroup != identifiers.leader)
            await Self.expectProcessExited(identifiers.child)
        }
    }

    @Test("Worker lifetime EOF terminates the supervised command group")
    func parentLifetimeEOFTerminatesSubprocessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-subprocess-parent-eof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let parentLifetime = Pipe()
        let target = URL(fileURLWithPath: "/usr/bin/perl")
        let targetArguments = [
            "-MPOSIX",
            "-e",
            #"""
            open(my $marker, '>', $ARGV[0]) or die "marker: $!";
            print $marker "$$ ", POSIX::getpgrp(), "\n";
            close($marker);
            while (1) { sleep 1; }
            """#,
            marker.path,
        ]
        let processIdentifier = try SimulatorPOSIXProcessLauncher().launch(
            executableURL: SimulatorParentLifetimeSupervisor.executableURL,
            arguments: SimulatorParentLifetimeSupervisor.arguments(
                executableURL: target,
                arguments: targetArguments
            ),
            environment: [:],
            currentDirectoryURL: nil,
            standardInputFD: parentLifetime.fileHandleForReading.fileDescriptor,
            standardOutputFD: nil,
            standardErrorFD: nil,
            fileDescriptorsToClose: [
                parentLifetime.fileHandleForReading.fileDescriptor,
                parentLifetime.fileHandleForWriting.fileDescriptor,
            ]
        )
        try? parentLifetime.fileHandleForReading.close()
        let identifiers = try await Self.requireSupervisorMarker(marker)
        #expect(identifiers.group == processIdentifier)

        try parentLifetime.fileHandleForWriting.close()
        var rawStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(processIdentifier, &rawStatus, 0)
        } while waitResult == -1 && errno == EINTR

        #expect(waitResult == processIdentifier)
        #expect(rawStatus & 0x7f == SIGKILL)
        await Self.expectProcessExited(identifiers.process)
    }

    private static func readProcessTreeMarker(
        _ marker: URL
    ) throws -> (leader: Int32, leaderGroup: Int32, child: Int32, childGroup: Int32) {
        let fields = try String(contentsOf: marker, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }
        guard fields.count == 4 else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The subprocess fixture did not publish its process tree."
            )
        }
        return (fields[0], fields[1], fields[2], fields[3])
    }

    private static func requireProcessTreeMarker(
        _ marker: URL
    ) async throws -> (leader: Int32, leaderGroup: Int32, child: Int32, childGroup: Int32) {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline {
            if let identifiers = try? readProcessTreeMarker(marker) { return identifiers }
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        throw SimulatorWorkerFailure.privateAPIUnavailable(
            "The subprocess fixture did not publish its process tree."
        )
    }

    private static func requireNormalExitMarker(
        _ marker: URL
    ) async throws -> (leader: Int32, leaderGroup: Int32, child: Int32) {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline {
            if let fields = try? String(contentsOf: marker, encoding: .utf8)
                .split(whereSeparator: \.isWhitespace)
                .compactMap({ Int32($0) }),
               fields.count == 3 {
                return (fields[0], fields[1], fields[2])
            }
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        throw SimulatorWorkerFailure.privateAPIUnavailable(
            "The normal-exit fixture did not publish its process tree."
        )
    }

    private static func requireSupervisorMarker(
        _ marker: URL
    ) async throws -> (process: Int32, group: Int32) {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline {
            if let fields = try? String(contentsOf: marker, encoding: .utf8)
                .split(whereSeparator: \.isWhitespace)
                .compactMap({ Int32($0) }),
               fields.count == 2 {
                return (fields[0], fields[1])
            }
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        throw SimulatorWorkerFailure.privateAPIUnavailable(
            "The supervisor fixture did not publish its process group."
        )
    }

    private static func expectProcessExited(_ processIdentifier: Int32) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline {
            if Darwin.kill(processIdentifier, 0) != 0, errno == ESRCH { return }
            try? await ContinuousClock().sleep(for: .milliseconds(10))
        }
        _ = Darwin.kill(processIdentifier, SIGKILL)
        Issue.record("The command descendant survived cancellation")
    }
}
