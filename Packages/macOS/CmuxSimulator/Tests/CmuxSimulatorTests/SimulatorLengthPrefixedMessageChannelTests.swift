import Darwin
import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator worker framing")
struct SimulatorLengthPrefixedMessageChannelTests {
    @Test("A frame round trips through POSIX pipes")
    func roundTripsFrame() throws {
        var hostToWorker = [Int32](repeating: 0, count: 2)
        var workerToHost = [Int32](repeating: 0, count: 2)
        #expect(pipe(&hostToWorker) == 0)
        #expect(pipe(&workerToHost) == 0)
        defer {
            for descriptor in hostToWorker + workerToHost { close(descriptor) }
        }

        let host = SimulatorLengthPrefixedMessageChannel(
            readFD: workerToHost[0],
            writeFD: hostToWorker[1]
        )
        let worker = SimulatorLengthPrefixedMessageChannel(
            readFD: hostToWorker[0],
            writeFD: workerToHost[1]
        )
        let payload = Data("hello simulator".utf8)

        try host.sendMessage(payload)
        #expect(worker.receiveMessage() == payload)
        try worker.sendMessage(payload)
        #expect(host.receiveMessage() == payload)
    }

    @Test("An oversized outbound frame is rejected before writing")
    func rejectsOversizedFrame() {
        let channel = SimulatorLengthPrefixedMessageChannel(readFD: -1, writeFD: -1)
        let payload = Data(count: SimulatorLengthPrefixedMessageChannel.maximumFrameLength + 1)

        #expect(throws: SimulatorChannelError.frameTooLarge) {
            try channel.sendMessage(payload)
        }
    }

    @Test("A non-reading worker poisons its bounded writer after one deadline")
    func nonReadingPipePoisonsWriter() throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        #expect(pipe(&descriptors) == 0)
        defer { descriptors.forEach { close($0) } }
        let failure = DispatchSemaphore(value: 0)
        let channel = SimulatorLengthPrefixedMessageChannel(
            readFD: -1,
            writeFD: descriptors[1],
            nonblockingWrites: true,
            writeDeadline: .milliseconds(20),
            writeFailureHandler: { failure.signal() }
        )

        try channel.sendMessage(Data(count: 1024 * 1024))
        #expect(failure.wait(timeout: .now() + 1) == .success)
        #expect(throws: SimulatorChannelError.writeFailed) {
            try channel.sendMessage(Data("must not reuse a partial frame".utf8))
        }
        channel.stopWriting()
    }

    @Test("A writer deadline terminates its non-reading worker")
    func writerDeadlineTerminatesWorker() async throws {
        let connection = try SimulatorProcessWorkerLauncher(
            terminationObservationTimeout: 0,
            terminationGrace: .zero,
            writeDeadline: .milliseconds(20)
        ).launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            environment: [:]
        )
        defer { connection.terminate() }
        let processIdentifier = try #require(connection.processIdentifier)

        try connection.send(Data(count: 1024 * 1024))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while kill(processIdentifier, 0) == 0, clock.now < deadline {
            await Task.yield()
        }

        #expect(kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
        #expect(throws: SimulatorChannelError.writeFailed) {
            try connection.send(Data("must not reach the terminated worker".utf8))
        }
    }

    @Test("A backpressured frame completes intact once its peer drains")
    func backpressuredFrameCompletes() throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        #expect(pipe(&descriptors) == 0)
        defer { descriptors.forEach { close($0) } }

        do {
            let host = SimulatorLengthPrefixedMessageChannel(
                readFD: -1,
                writeFD: descriptors[1],
                nonblockingWrites: true
            )
            let worker = SimulatorLengthPrefixedMessageChannel(
                readFD: descriptors[0],
                writeFD: -1
            )
            let payload = Data(repeating: 0x5a, count: 1024 * 1024)

            try host.sendMessage(payload)
            host.finishWriting {}
            #expect(worker.receiveMessage() == payload)
            host.stopWriting()
        }
    }

    @Test("A closed worker pipe reports EPIPE without terminating the host")
    func closedWorkerPipeDoesNotRaiseSIGPIPE() {
        var descriptors = [Int32](repeating: 0, count: 2)
        #expect(pipe(&descriptors) == 0)
        let channel = SimulatorLengthPrefixedMessageChannel(
            readFD: -1,
            writeFD: descriptors[1]
        )
        close(descriptors[0])
        defer { close(descriptors[1]) }

        #expect(throws: SimulatorChannelError.writeFailed) {
            try channel.sendMessage(Data("worker exited".utf8))
        }
    }

    @Test("The bounded frame queue preserves FIFO order and rejects overflow")
    func boundedQueueOverflows() async {
        let queue = SimulatorBoundedMessageQueue<Int>(limit: 3)
        #expect(queue.yield(1) == .enqueued)
        #expect(queue.yield(2) == .enqueued)
        #expect(queue.yield(3) == .enqueued)
        #expect(queue.yield(4) == .overflow)
        queue.finish()

        var values: [Int] = []
        for await value in queue.stream { values.append(value) }
        #expect(values == [1, 2, 3])
    }

    @Test("Host frame queue overflow terminates the worker and records a recoverable failure")
    func hostQueueOverflowTerminatesWorker() async throws {
        let connection = try SimulatorProcessWorkerLauncher().launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 10000 ]; do printf '\\000\\000\\000\\001R'; i=$((i+1)); done; sleep 30",
            ],
            environment: [:]
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while connection.terminalFailure() == nil, clock.now < deadline {
            await Task.yield()
        }
        try #require(connection.terminalFailure()?.code == "worker_protocol_queue_overflow")

        var received = 0
        var receivedBytes = 0
        for await frame in connection.messages {
            received += 1
            receivedBytes += frame.count
        }

        #expect(received <= SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount)
        #expect(receivedBytes <= SimulatorLengthPrefixedMessageChannel.maximumBufferedPayloadBytes)
        #expect(SimulatorLengthPrefixedMessageChannel.maximumBufferedPayloadBytes == 32 * 1024 * 1024)
        #expect(connection.terminalFailure()?.code == "worker_protocol_queue_overflow")
    }

    @Test("Worker inbound queue overflow exit is surfaced as a recoverable failure")
    func workerQueueOverflowExitIsClassified() async throws {
        let status = SimulatorLengthPrefixedMessageChannel.protocolQueueOverflowExitStatus
        let connection = try SimulatorProcessWorkerLauncher().launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit \(status)"],
            environment: [:]
        )
        for await _ in connection.messages {}

        let failure = connection.terminalFailure()
        #expect(failure?.code == "worker_protocol_queue_overflow")
        #expect(failure?.isRecoverable == true)
    }

    @Test("Exit-75 classification remains deterministic under concurrent process load")
    func concurrentWorkerQueueOverflowExitClassification() async throws {
        let status = SimulatorLengthPrefixedMessageChannel.protocolQueueOverflowExitStatus
        let failures = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let connection = try SimulatorProcessWorkerLauncher().launch(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "exit \(status)"],
                        environment: [:]
                    )
                    for await _ in connection.messages {}
                    return connection.terminalFailure()?.code
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(failures.count == 32)
        #expect(failures.allSatisfy { $0 == "worker_protocol_queue_overflow" })
    }

    @Test("A live child that closes stdout cannot hold the reader indefinitely")
    func liveChildClosedOutputUsesBoundedFallback() async throws {
        let connection = try SimulatorProcessWorkerLauncher(
            terminationObservationTimeout: 0
        ).launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 1>&-; while :; do :; done"],
            environment: [:]
        )

        for await _ in connection.messages {}
        #expect(connection.terminalFailure() == nil)
        connection.terminate()
    }

    @Test("Dropping the last worker connection cannot orphan its subprocess")
    func droppedConnectionKillsWorker() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worker-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        var connection: SimulatorWorkerConnection? = try SimulatorProcessWorkerLauncher().launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "echo $$ > '\(marker.path)'; trap '' TERM; while :; do :; done",
            ],
            environment: [:]
        )
        for _ in 0..<10_000 where !FileManager.default.fileExists(atPath: marker.path) {
            await Task.yield()
        }
        let processIdentifier = try #require(Int32(
            String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))

        connection = nil
        _ = connection
        #expect(await Self.waitUntilProcessExits(processIdentifier))
    }

    @Test("Host cleanup kills a worker subprocess and its grandchild")
    func terminationKillsWorkerProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worker-group-\(UUID().uuidString)")
        var workerIdentifier: Int32?
        var subprocessIdentifier: Int32?
        var grandchildIdentifier: Int32?
        var connection: SimulatorWorkerConnection? = try SimulatorProcessWorkerLauncher().launch(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-MPOSIX",
                "-e",
                #"""
                POSIX::setpgid(0, 0) == 0 or die "setpgid: $!";
                $SIG{TERM} = 'IGNORE';
                my $worker = $$;
                my $subprocess = fork();
                defined($subprocess) or die "fork: $!";
                if ($subprocess == 0) {
                    my $subprocess_identifier = $$;
                    my $grandchild = fork();
                    defined($grandchild) or die "fork: $!";
                    if ($grandchild == 0) {
                        open(my $marker, '>', $ARGV[0]) or die "marker: $!";
                        print $marker "$worker $subprocess_identifier $$\n";
                        close($marker);
                        while (1) { sleep 1; }
                    }
                    while (1) { sleep 1; }
                }
                while (1) { sleep 1; }
                """#,
                marker.path,
            ],
            environment: [:]
        )
        defer {
            connection?.terminate()
            if let workerIdentifier { _ = Darwin.kill(workerIdentifier, SIGKILL) }
            if let subprocessIdentifier { _ = Darwin.kill(subprocessIdentifier, SIGKILL) }
            if let grandchildIdentifier { _ = Darwin.kill(grandchildIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: marker)
        }

        let identifiers = try await Self.readProcessIdentifiers(from: marker)
        workerIdentifier = identifiers.worker
        subprocessIdentifier = identifiers.subprocess
        grandchildIdentifier = identifiers.grandchild
        let hostGroup = getpgrp()
        #expect(getpgid(identifiers.worker) == identifiers.worker)
        #expect(getpgid(identifiers.subprocess) == identifiers.worker)
        #expect(getpgid(identifiers.grandchild) == identifiers.worker)
        #expect(!SimulatorWorkerProcessGroup(
            hostGroupIdentifier: hostGroup
        ).isSafeWorkerGroup(hostGroup))

        connection?.terminate()
        #expect(await Self.waitUntilProcessExits(identifiers.worker))
        #expect(await Self.waitUntilProcessExits(identifiers.subprocess))
        #expect(await Self.waitUntilProcessExits(identifiers.grandchild))
        for await _ in try #require(connection).messages {}
        connection = nil
    }

    private static func readProcessIdentifiers(
        from marker: URL
    ) async throws -> (worker: Int32, subprocess: Int32, grandchild: Int32) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if let value = try? String(contentsOf: marker, encoding: .utf8) {
                let fields = value.split(whereSeparator: \.isWhitespace)
                if fields.count == 3,
                   let worker = Int32(fields[0]),
                   let subprocess = Int32(fields[1]),
                   let grandchild = Int32(fields[2]) {
                    return (worker, subprocess, grandchild)
                }
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw SimulatorControlError(
            code: "process_group_marker_timeout",
            arguments: [],
            message: "The process-group test helper did not publish its PIDs."
        )
    }

    private static func waitUntilProcessExits(_ processIdentifier: Int32) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if Darwin.kill(processIdentifier, 0) != 0, errno == ESRCH { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return Darwin.kill(processIdentifier, 0) != 0 && errno == ESRCH
    }
}
