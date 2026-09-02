@testable import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo CLI behavior")
struct SudoCLIBehaviorTests {
    @Test("Touch ID setup runs the helper bundled with the enclosing app")
    func touchIDSetupUsesBundledHelper() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let output = TestCLIOutput()
        let launcher = RecordingTouchIDSetupLauncher(exitCode: 17)
        let helperURL = fixture.root.appendingPathComponent("setup-pam-tid.sh")
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
            launcher: TestAppLauncher(),
            setupLauncher: launcher,
            setupHelperURL: helperURL,
            io: output.io,
            failureMessages: .testMessages,
            now: { Date(timeIntervalSince1970: 1) }
        )

        let exitCode = try command.run(arguments: ["setup-touch-id"])

        #expect(exitCode == 17)
        #expect(launcher.helperURLs == [helperURL])
    }

    @Test("Standard input is read through the script-size bound")
    func standardInputIsBounded() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let output = TestCLIOutput()
        output.standardInput = Data(repeating: 0x61, count: 256 * 1_024 + 1)
        let command = Self.command(fixture: fixture, output: output)

        #expect(throws: SudoCLICommandError.self) {
            try command.run(arguments: ["run", "-"])
        }
        #expect(output.requestedStandardInputByteCounts == [256 * 1_024 + 1])
        #expect(fixture.store.pendingRequests().isEmpty)
    }

    @Test("Standard input overflow reports the script-size error")
    func standardInputOverflowUsesSpecificError() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let output = TestCLIOutput()
        output.standardInputError = SudoBoundedInputReader.Failure.tooLarge
        let command = Self.command(fixture: fixture, output: output)

        do {
            _ = try command.run(arguments: ["run", "-"])
            Issue.record("Expected standard-input overflow to fail")
        } catch let error as SudoCLICommandError {
            #expect(error.message.contains("script exceeds"))
            #expect(error.exitCode == 2)
        }
        #expect(fixture.store.pendingRequests().isEmpty)
    }

    @Test("Non-regular script input fails without reading the device")
    func nonRegularFileIsRejected() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let output = TestCLIOutput()
        let command = Self.command(fixture: fixture, output: output)

        #expect(throws: SudoCLICommandError.self) {
            try command.run(arguments: ["run", "/dev/zero"])
        }
        #expect(fixture.store.pendingRequests().isEmpty)
    }

    @Test("Pending admission failures are reported as capacity errors")
    func pendingAdmissionFailureIsSpecific() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        for index in 0..<8 {
            _ = try fixture.enqueue(id: "cli-capacity-\(index)", createdAt: .now)
        }
        let output = TestCLIOutput()
        let command = Self.command(fixture: fixture, output: output)

        do {
            _ = try command.run(arguments: ["run", "-c", "echo overflow"])
            Issue.record("Expected pending admission to fail")
        } catch let error as SudoCLICommandError {
            #expect(error.message.contains("too many approval requests"))
        }
    }

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

    @Test(
        "A result-wait failure preserves an approved execution",
        .timeLimit(.minutes(1))
    )
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
        try fixture.store.settle(
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
        try fixture.store.settle(
            SudoResult(id: requestID, status: .completed, exitCode: 0)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: outputURL.path
        )

        try fixture.store.ensureDirectories()

        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    private static func command(
        fixture: SudoTestFixture,
        output: TestCLIOutput
    ) -> SudoCLICommand {
        SudoCLICommand(
            store: fixture.store,
            appBundleURL: URL(fileURLWithPath: "/Applications/cmux.app"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            requesterIdentity: SudoProcessIdentity(
                processIdentifier: 42,
                startSeconds: 10,
                startMicroseconds: 20
            ),
            requesterCommand: "test-agent",
            launcher: TestAppLauncher(),
            io: output.io,
            failureMessages: .testMessages,
            now: { Date(timeIntervalSince1970: 1) }
        )
    }
}

private final class RecordingTouchIDSetupLauncher: SudoTouchIDSetupLaunching {
    private let exitCode: Int32
    private(set) var helperURLs: [URL] = []

    init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    func run(helperURL: URL) throws -> Int32 {
        helperURLs.append(helperURL)
        return exitCode
    }
}

private final class TestCLIOutput {
    private(set) var standardOutput = Data()
    private(set) var standardError = ""
    private(set) var requestedStandardInputByteCounts: [Int] = []
    var standardInput = Data()
    var standardInputError: Error?

    var io: SudoCLIIO {
        SudoCLIIO(
            readStandardInput: { [weak self] maximumBytes in
                self?.requestedStandardInputByteCounts.append(maximumBytes)
                if let error = self?.standardInputError { throw error }
                return Data((self?.standardInput ?? Data()).prefix(maximumBytes))
            },
            writeStandardOutput: { [weak self] in self?.standardOutput.append($0) },
            writeStandardError: { [weak self] in self?.standardError += $0 + "\n" }
        )
    }
}
