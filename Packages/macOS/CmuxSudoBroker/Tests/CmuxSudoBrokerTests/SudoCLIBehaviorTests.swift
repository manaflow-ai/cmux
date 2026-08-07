@testable import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo CLI behavior")
struct SudoCLIBehaviorTests {
    @Test("An unapproved CLI timeout settles the durable request")
    func pendingTimeoutSettlesRequest() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let output = TestCLIOutput()
        let requesterIdentity = SudoProcessIdentity(
            processIdentifier: 42,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let command = SudoCLICommand(
            store: fixture.store,
            appBundleURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            requesterIdentity: requesterIdentity,
            requesterCommand: "test-agent",
            launcher: TestAppLauncher(),
            io: output.io,
            failureMessages: .testMessages,
            now: { Date(timeIntervalSince1970: 1) }
        )

        let exitCode = try command.run(arguments: ["run", "-t", "1", "-c", "echo ok"])

        #expect(exitCode == 124)
        let request = try #require(try fixture.archivedRequest())
        #expect(request.requesterIdentity == requesterIdentity)
        let result = try #require(fixture.store.result(id: request.id))
        #expect(result.errorCode == .approvalTimedOut)
        #expect(output.standardError.contains("not approved"))
    }

    @Test("A result-wait failure preserves an approved execution")
    func waitFailureReportsApprovedExecution() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let output = TestCLIOutput()
        let now = Date.now
        let paths = fixture.paths
        let launcher = TestAppLauncher {
            let store = SudoSpoolStore(paths: paths)
            guard let pending = store.pendingRequests().first else {
                throw CocoaError(.fileNoSuchFile)
            }
            _ = try store.transitionToApproved(
                pending: pending,
                now: now,
                executionGraceSeconds: SudoBroker.executionGraceSeconds
            )
            try FileManager.default.createSymbolicLink(
                at: store.outputURL(id: pending.request.id),
                withDestinationURL: URL(fileURLWithPath: "/dev/null")
            )
        }
        let command = SudoCLICommand(
            store: fixture.store,
            appBundleURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            requesterIdentity: SudoProcessIdentity(
                processIdentifier: 42,
                startSeconds: 10,
                startMicroseconds: 20
            ),
            requesterCommand: "test-agent",
            launcher: launcher,
            io: output.io,
            failureMessages: .testMessages,
            now: { now }
        )

        let exitCode = try command.run(arguments: ["run", "-t", "60", "-c", "echo ok"])

        #expect(exitCode == 124)
        #expect(output.standardError.contains("was approved"))
        let pending = try #require(fixture.store.pendingRequests().first)
        #expect(fixture.store.state(id: pending.request.id)?.phase == .approved)
        #expect(fixture.store.result(id: pending.request.id) == nil)
    }

    @Test("A terminal result removes output after the CLI consumes it")
    func terminalResultRemovesConsumedOutput() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let output = TestCLIOutput()
        let requestID = "consumed-output"
        let outputURL = fixture.store.outputURL(id: requestID)
        try Data("root output\n".utf8).write(to: outputURL)
        try fixture.store.writeResultIfAbsent(
            SudoResult(id: requestID, status: .completed, exitCode: 0)
        )
        let waiter = SudoResultWaiter(store: fixture.store, io: output.io)

        let outcome = try waiter.wait(
            requestID: requestID,
            deadline: Date.now.addingTimeInterval(10),
            approvalTimeoutNote: "timed out"
        )

        #expect(outcome == .result(SudoResult(id: requestID, status: .completed, exitCode: 0)))
        #expect(output.standardOutput == Data("root output\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test("Old abandoned terminal output is pruned on spool maintenance")
    func staleTerminalOutputIsPruned() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let requestID = "abandoned-output"
        let outputURL = fixture.store.outputURL(id: requestID)
        try Data("uncollected\n".utf8).write(to: outputURL)
        try fixture.store.writeResultIfAbsent(
            SudoResult(id: requestID, status: .completed, exitCode: 0)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: outputURL.path
        )

        try fixture.store.ensureDirectories()

        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }
}

private final class TestCLIOutput {
    private(set) var standardOutput = Data()
    private(set) var standardError = ""

    var io: SudoCLIIO {
        SudoCLIIO(
            readStandardInput: { Data() },
            writeStandardOutput: { [weak self] in self?.standardOutput.append($0) },
            writeStandardError: { [weak self] in self?.standardError += $0 + "\n" }
        )
    }
}
