@testable import CmuxSudoBroker
import Darwin
import Foundation
import Testing

@Suite("Sudo process lifecycle")
struct SudoProcessLifecycleTests {
    @Test("Raw PTY receiver transfers exactly the reviewed bytes", .timeLimit(.minutes(1)))
    func privilegedPTYReceiverIsByteExact() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        #expect(openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0)
        try #require(masterDescriptor >= 0 && slaveDescriptor >= 0)
        defer {
            Darwin.close(masterDescriptor)
            Darwin.close(slaveDescriptor)
        }
        let reviewedBytes = Data([0, 1, 2, 3, 10, 13, 0xff])
        let readinessMarker = SudoExecutionControlMarkers().inputReady
        let writerDescriptor = masterDescriptor
        Thread.detachNewThread {
            var receivedMarker = Data(count: readinessMarker.count)
            var markerOffset = 0
            while markerOffset < receivedMarker.count {
                let remainingMarkerCount = receivedMarker.count - markerOffset
                let count = receivedMarker.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        writerDescriptor,
                        bytes.baseAddress?.advanced(by: markerOffset),
                        remainingMarkerCount
                    )
                }
                if count > 0 {
                    markerOffset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
            guard receivedMarker == readinessMarker else { return }
            var scriptOffset = 0
            while scriptOffset < reviewedBytes.count {
                let count = reviewedBytes.withUnsafeBytes { bytes in
                    Darwin.write(
                        writerDescriptor,
                        bytes.baseAddress?.advanced(by: scriptOffset),
                        reviewedBytes.count - scriptOffset
                    )
                }
                if count > 0 {
                    scriptOffset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
        let receiver = SudoPrivilegedScriptReceiver(
            inputDescriptor: slaveDescriptor,
            outputDescriptor: slaveDescriptor,
            temporaryDirectoryURL: fixture.root
        )

        let receivedBytes = try receiver.withReceivedDescriptor(
            expectedByteCount: reviewedBytes.count
        ) { descriptor in
            try SudoReviewedScriptReader(descriptor: descriptor).read()
        }

        #expect(receivedBytes == reviewedBytes)
    }

    @Test("Privileged supervisor rejects an expired deadline before spawning")
    func expiredPrivilegedDeadlineDoesNotSpawn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let supervisor = SudoPrivilegedProcessSupervisor(
            now: { now },
            preflightNow: { now }
        )

        let outcome = supervisor.execute(
            scriptDescriptor: -1,
            displayName: "expired.sh",
            deadline: now.addingTimeInterval(-1)
        )

        #expect(outcome == .timedOut)
    }

    @Test("Detached runner reaper collects its child", .timeLimit(.minutes(1)))
    func detachedRunnerReaperCollectsChild() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let inspector = SystemSudoProcessInspector()
        let spawner = SudoPOSIXProcessSpawner(inspector: inspector)
        let command = SudoExecutionCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["/bin/sh", "-c", "kill -STOP $$; exit 0"],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            outputURL: fixture.paths.results.appendingPathComponent("runner-reaper.out")
        )
        let process = try spawner.spawn(command)
        var stoppedStatus: Int32 = 0
        #expect(
            waitpid(
                process.identity.processIdentifier,
                &stoppedStatus,
                WUNTRACED
            ) == process.identity.processIdentifier
        )
        let reaper = SudoChildProcessReaper()
        let stream = reaper.start(processIdentifier: process.identity.processIdentifier)

        _ = kill(process.identity.processIdentifier, SIGCONT)
        var iterator = stream.makeAsyncIterator()
        let reapedProcessIdentifier = await iterator.next()

        #expect(reapedProcessIdentifier == process.identity.processIdentifier)
        var status: Int32 = 0
        #expect(waitpid(process.identity.processIdentifier, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("Execution deadline terminates a script PTY tree", .timeLimit(.minutes(1)))
    func boundedRunnerTerminatesPTYTree() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let inspector = SystemSudoProcessInspector()
        let signaler = SystemSudoProcessSignaler()
        let runner = SudoBoundedProcessRunner(
            spawner: SudoPOSIXProcessSpawner(inspector: inspector),
            inspector: inspector,
            signaler: signaler
        )
        let command = SudoExecutionCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: [
                "/usr/bin/script", "-q", "/dev/null", "/bin/sh", "-c", "sleep 30",
            ],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            outputURL: fixture.paths.results.appendingPathComponent("pty-timeout.out")
        )

        let process = try runner.spawn(command)
        let outcome = runner.wait(
            for: process,
            deadline: Date.now.addingTimeInterval(0.2)
        )

        guard case .timedOut(let survivors) = outcome else {
            Issue.record("process exited before the deadline instead of exercising cleanup")
            return
        }
        #expect(survivors.isEmpty)
        #expect(!inspector.isRunning(process.identity))
    }

    @Test(
        "Password fallback terminates the script PTY tree before the deadline",
        .timeLimit(.minutes(1))
    )
    func passwordFallbackTerminatesPTYTree() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let inspector = SystemSudoProcessInspector()
        let signaler = SystemSudoProcessSignaler()
        let runner = SudoBoundedProcessRunner(
            spawner: SudoPOSIXProcessSpawner(inspector: inspector),
            inspector: inspector,
            signaler: signaler
        )
        let command = SudoExecutionCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: [
                "/usr/bin/script", "-q", "/dev/null", "/bin/sh", "-c",
                "printf '\(SudoAuthenticationOutputDetector.passwordPrompt)'; sleep 30",
            ],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            outputURL: fixture.paths.results.appendingPathComponent("pty-password.out")
        )

        let process = try runner.spawn(command)
        let outcome = runner.wait(
            for: process,
            deadline: Date.now.addingTimeInterval(10)
        )

        if case .authenticationFailed(let survivors) = outcome {
            #expect(survivors.isEmpty)
        } else {
            let output = (try? String(contentsOf: command.outputURL, encoding: .utf8)) ?? ""
            Issue.record(
                "password fallback produced \(outcome); captured output: \(output.debugDescription)"
            )
        }
        #expect(!inspector.isRunning(process.identity))
    }

    @Test("Execution output is capped while the child is fully drained", .timeLimit(.minutes(1)))
    func executionOutputIsBounded() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let inspector = SystemSudoProcessInspector()
        let runner = SudoBoundedProcessRunner(
            spawner: SudoPOSIXProcessSpawner(inspector: inspector),
            inspector: inspector,
            signaler: SystemSudoProcessSignaler()
        )
        let outputURL = fixture.paths.results.appendingPathComponent("bounded-output.out")
        let command = SudoExecutionCommand(
            executableURL: URL(fileURLWithPath: "/bin/dd"),
            arguments: [
                "/bin/dd", "if=/dev/zero", "bs=1048576", "count=17",
            ],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            outputURL: outputURL
        )

        let process = try runner.spawn(command)
        let outcome = runner.wait(
            for: process,
            deadline: Date.now.addingTimeInterval(10)
        )
        let outputSize = try #require(
            FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
        )

        #expect(outcome == .exited(0))
        #expect(outputSize.intValue <= 16 * 1_024 * 1_024)
    }

    @Test("Privileged supervisor executes reviewed bytes instead of the approved pathname", .timeLimit(.minutes(2)))
    func reviewedScriptTransportIsImmutable() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let approvedScriptURL = fixture.paths.approved.appendingPathComponent("immutable.sh")
        try Data("printf 'replaced-path\\n'\n".utf8).write(to: approvedScriptURL)
        let outputURL = fixture.paths.results.appendingPathComponent("immutable.out")
        let reviewedScript = Data(
            "[ -w /dev/fd/1 ] || exit 91\nprintf 'reviewed-bytes\\n' > '\(outputURL.path)'\n".utf8
        )
        let capability = SudoReviewedScriptCapability(
            bytes: reviewedScript,
            temporaryDirectoryURL: fixture.root
        )
        let outcome = try capability.withDescriptor { descriptor in
            SudoPrivilegedProcessSupervisor().execute(
                scriptDescriptor: descriptor,
                displayName: approvedScriptURL.path,
                deadline: Date.now.addingTimeInterval(60)
            )
        }
        try #require(outcome == SudoPrivilegedProcessOutcome.exited(0))
        let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)

        #expect(output.contains("reviewed-bytes"))
        #expect(!output.contains("replaced-path"))
    }

    @Test("Privileged deadline kills a TERM-resistant process group", .timeLimit(.minutes(1)))
    func privilegedDeadlineKillsStubbornGroup() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let rootPIDURL = fixture.root.appendingPathComponent("root.pid")
        let childPIDURL = fixture.root.appendingPathComponent("child.pid")
        let startupFIFOURL = fixture.root.appendingPathComponent("started.fifo")
        try startupFIFOURL.path.withCString { path in
            guard mkfifo(path, mode_t(0o600)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let startupDescriptor = startupFIFOURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_NONBLOCK)
        }
        try #require(startupDescriptor >= 0)
        defer { Darwin.close(startupDescriptor) }
        let script = Data(
            """
            trap '' TERM
            echo $$ > '\(rootPIDURL.path)'
            /bin/sh -c 'trap "" TERM; echo $$ > "\(childPIDURL.path)"; while :; do /bin/sleep 30; done' &
            printf x > '\(startupFIFOURL.path)'
            wait
            """.utf8
        )
        let capability = SudoReviewedScriptCapability(
            bytes: script,
            temporaryDirectoryURL: fixture.root
        )
        let deadline = Date.now.addingTimeInterval(60)
        let supervisor = SudoPrivilegedProcessSupervisor(now: {
            var state = pollfd(fd: startupDescriptor, events: Int16(POLLIN), revents: 0)
            var pollResult: Int32
            repeat {
                pollResult = Darwin.poll(&state, 1, 30_000)
            } while pollResult < 0 && errno == EINTR
            if pollResult > 0 {
                var byte: UInt8 = 0
                _ = Darwin.read(startupDescriptor, &byte, 1)
            }
            return deadline.addingTimeInterval(1)
        })

        let outcome = try capability.withDescriptor { descriptor in
            supervisor.execute(
                scriptDescriptor: descriptor,
                displayName: "stubborn.sh",
                deadline: deadline
            )
        }
        try #require(outcome == .timedOut)
        let rootPID = Int32(
            try String(contentsOf: rootPIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let childPID = Int32(
            try String(contentsOf: childPIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        #expect(rootPID.map { kill($0, 0) != 0 && errno == ESRCH } == true)
        #expect(childPID.map { kill($0, 0) != 0 && errno == ESRCH } == true)
    }

    @Test("Privileged completion kills residual root process group", .timeLimit(.minutes(1)))
    func privilegedCompletionKillsResidualGroup() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let childPIDURL = fixture.root.appendingPathComponent("residual-child.pid")
        let startupFIFOURL = fixture.root.appendingPathComponent("residual-started.fifo")
        try startupFIFOURL.path.withCString { path in
            guard mkfifo(path, mode_t(0o600)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let script = Data(
            """
            /bin/sh -c 'trap "" TERM; echo $$ > "\(childPIDURL.path)"; printf x > "\(startupFIFOURL.path)"; while :; do /bin/sleep 30; done' &
            /bin/dd if='\(startupFIFOURL.path)' of=/dev/null bs=1 count=1 2>/dev/null
            exit 7
            """.utf8
        )
        let capability = SudoReviewedScriptCapability(
            bytes: script,
            temporaryDirectoryURL: fixture.root
        )

        let outcome = try capability.withDescriptor { descriptor in
            SudoPrivilegedProcessSupervisor().execute(
                scriptDescriptor: descriptor,
                displayName: "residual.sh",
                deadline: Date.now.addingTimeInterval(15)
            )
        }
        try #require(outcome == .exited(7))
        let childPID = Int32(
            try String(contentsOf: childPIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        #expect(childPID.map { kill($0, 0) != 0 && errno == ESRCH } == true)
    }

    @Test("System process inventory includes the calling process")
    func systemProcessInventoryIncludesSelf() {
        let processIdentifiers = SystemSudoProcessInspector().allProcessIdentifiers()

        #expect(processIdentifiers.contains(getpid()))
    }

    @Test("Hidden runner parent failure settles the approved request")
    func runnerSettlesUnexpectedParent() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let createdAt = Date.now
        let request = try fixture.enqueue(id: "parent-validation", createdAt: createdAt)
        let pending = try #require(
            fixture.store.pendingRequests().first(where: { $0.request.id == request.id })
        )
        _ = try fixture.store.transitionToApproved(
            pending: pending,
            now: createdAt,
            executionGraceSeconds: 90
        )
        let runner = SudoExecutionRunner(
            paths: fixture.paths,
            expectedParentExecutableURL: URL(fileURLWithPath: "/not/the/test-parent"),
            privilegedHelperExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
            messages: .testMessages,
            pamConfiguration: SudoPAMConfiguration(
                fileURL: fixture.root.appendingPathComponent("missing-pam")
            )
        )

        #expect(runner.run(requestID: request.id) == 126)
        #expect(fixture.store.result(id: request.id)?.errorCode == .runnerLaunchFailed)
        #expect(fixture.store.state(id: request.id) == nil)
    }

    @Test("Hidden runner identity failure settles the approved request")
    func runnerSettlesMissingIdentity() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let createdAt = Date.now
        let request = try fixture.enqueue(id: "runner-identity", createdAt: createdAt)
        let pending = try #require(
            fixture.store.pendingRequests().first(where: { $0.request.id == request.id })
        )
        _ = try fixture.store.transitionToApproved(
            pending: pending,
            now: createdAt,
            executionGraceSeconds: 90
        )
        let expectedParentURL = URL(fileURLWithPath: "/Applications/cmux.app/Contents/MacOS/cmux")
        let inspector = TestRunnerBootstrapInspector(
            parentProcessIdentifier: 2_000_000_000,
            parentExecutableURL: expectedParentURL
        )
        let runner = SudoExecutionRunner(
            store: fixture.store,
            pam: TestPAMChecker(enabled: true),
            inspector: inspector,
            parentValidator: SudoRunnerParentValidator(
                inspector: inspector,
                parentProcessIdentifier: { 2_000_000_000 }
            ),
            processRunner: SudoBoundedProcessRunner(
                spawner: SudoPOSIXProcessSpawner(inspector: inspector),
                inspector: inspector,
                signaler: SystemSudoProcessSignaler()
            ),
            expectedParentExecutableURL: expectedParentURL,
            messages: .testMessages,
            now: { createdAt }
        )

        #expect(runner.run(requestID: request.id) == 1)
        #expect(fixture.store.result(id: request.id)?.errorCode == .runnerLaunchFailed)
        #expect(fixture.store.state(id: request.id) == nil)
    }
}
