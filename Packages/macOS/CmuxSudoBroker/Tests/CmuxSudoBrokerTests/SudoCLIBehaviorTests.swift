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
