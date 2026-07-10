import Darwin
import Foundation
import Testing
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

    @Test("Worker subprocess trees remain in the worker process group")
    func subprocessTreeInheritsWorkerProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-subprocess-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = SimulatorSubprocessRunner(timeout: .seconds(2))
        let result = try await runner.run(
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
                while (!-e $ARGV[0]) { select(undef, undef, undef, 0.001); }
                exit 0;
                """#,
                marker.path,
            ]
        )
        let identifiers = try Self.readProcessTreeMarker(marker)
        defer { _ = Darwin.kill(identifiers.child, SIGKILL) }
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(identifiers.leaderGroup == getpgrp())
        #expect(identifiers.childGroup == getpgrp())
        #expect(identifiers.leaderGroup != identifiers.leader)
        #expect(Darwin.kill(identifiers.child, 0) == 0)
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
}

private actor FastEscalationSubprocessSleeper: SimulatorSubprocessSleeping {
    private(set) var callCount = 0

    func sleep(for duration: Duration) async throws {
        callCount += 1
        if duration == .milliseconds(50) {
            try await ContinuousClock().sleep(for: duration)
        }
    }
}
