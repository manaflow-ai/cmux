@testable import CmuxSudoBroker
import Darwin
import Foundation
import Testing

@Suite("Sudo process lifecycle")
struct SudoProcessLifecycleTests {
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

    @Test("Execution deadline terminates a script PTY tree")
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

    @Test("Password fallback terminates the script PTY tree before the deadline")
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
            deadline: Date.now.addingTimeInterval(1)
        )

        if case .authenticationFailed(let survivors) = outcome {
            #expect(survivors.isEmpty)
        } else {
            Issue.record("password fallback did not produce an authentication failure")
        }
        #expect(!inspector.isRunning(process.identity))
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
