import CmuxNextCloud
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp

/// A Cloud machine too old to update in place (`machine_update_unsupported`: no `fs-v1` or
/// `detached-terminals-v1`) is updated through the Cloud API's exec instead
/// (``CloudLegacyMachineUpdate``), and stays "cannot update" only when it has no exec either.
/// The exec and the machine are fakes; the guest script is the fleet's own, kept identical.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudLegacyMachineUpdateTests {
    static let bundled = CloudMachineUpdateTargetTests.bundled
    static let pin = CloudLegacyMachineUpdate.Pin(commit: String(repeating: "b", count: 40), sha256: String(repeating: "a", count: 64))
    static let unsupported = CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unsupported", error: "too old to update in place (no fs-v1)")

    /// Leo's machines (tidy-yellow-tern) stayed "too old to update in place" for good. Now the CLI's
    /// `machine_update_unsupported` runs the update through exec: the machine is updated, with no
    /// notice, its connection is pointed at the new daemon, and nothing says it cannot update.
    @Test func aMachineTooOldToUpdateInPlaceIsUpdatedThroughExec() async throws {
        let machine = FakeCloudMachine(build: CloudMachineUpdateTargetTests.older, level: .limited, answers: [Self.unsupported],
                                       legacy: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)

        #expect(machine.updates == 1)
        #expect(machine.legacyUpdates == 1)
        #expect(fixture.states == [.updating, .updated(build: Self.bundled)])
        #expect(machine.reconnectRestarts == [true], "the connection is pointed at the new daemon")
        #expect(fixture.notices.isEmpty)
        #expect(fixture.board.otherMachines == nil, "an updated machine still listed as one that cannot update")
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "updated"])
    }

    /// No exec (or no pinned build in this app): the machine stays "cannot update", as before.
    @Test func withoutExecTheMachineStillCannotUpdate() async throws {
        let machine = FakeCloudMachine(build: CloudMachineUpdateTargetTests.older, level: .limited, answers: [Self.unsupported])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)

        #expect(machine.legacyUpdates == 0)
        #expect(fixture.board.targets[CloudMachineUpdateTarget.id("vm-1")]?.state == .cannotUpdate(reason: CloudMachineUpdateStrings.unsupported("Leo VM")))
        #expect(fixture.notices.isEmpty)
    }

    /// A rolled-back exec update is a rollback (one notice), and asks for no second exec run.
    @Test func aRollbackThroughExecIsARollback() async throws {
        let machine = FakeCloudMachine(build: CloudMachineUpdateTargetTests.older, level: .limited, answers: [Self.unsupported],
                                       legacy: [CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_rolled_back", error: "ROLLBACK new-daemon-unstable")])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)

        #expect(machine.legacyUpdates == 1)
        #expect(fixture.states.last == .failed(reason: "ROLLBACK new-daemon-unstable", rolledBack: true))
        #expect(machine.reconnectRestarts == [true])
    }

    /// One exec carries the whole run: the pinned install and the guest script, started as root in
    /// a transient unit the exec waits on, with the route's longest timeout. Its result line is
    /// the answer.
    @Test func oneExecRunsTheGuestScriptWithThePinnedInstall() async throws {
        let calls = ExecRecorder(stdout: "OK upgraded terminals=3->3 daemon=812 hosts-before=3\n")
        let answer = await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "echo guest\n", nonce: "0123456789abcdef", exec: calls.exec)

        #expect(answer == CloudMoveCLI.Answer(ok: true, updated: true, build: Self.pin.commit))
        let (command, timeout) = try #require(calls.only)
        #expect(timeout == 900_000)
        #expect(command.contains("r=/var/lib/cmux-tui-upgrade/app-0123456789abcdef"))
        #expect(command.contains(Data(CloudLegacyMachineUpdate.installCommand(Self.pin).utf8).base64EncodedString()))
        #expect(command.contains(Data("echo guest\n".utf8).base64EncodedString()))
        #expect(command.contains("systemd-run --quiet --collect --wait --unit=cmux-app-tui-update-0123456789abcdef /bin/sh \"$r/upgrade.sh\" \(Self.pin.sha256) \(Self.pin.commit) \"$r\""))
        let install = CloudLegacyMachineUpdate.installCommand(Self.pin)
        #expect(install.contains("'https://files.cmux.com/cmux-tui/\(Self.pin.commit)/cmux-tui-x86_64-unknown-linux-musl'"))
        #expect(install.contains("printf '%s  %s\\n' \(Self.pin.sha256) \"$tmp\" | sha256sum -c"), "the download is checked against the pin")

        let lost = await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "", exec: { _, _ in throw CloudAPIError.timedOut("exec") })
        #expect(lost.errorCode == "machine_update_unresolved", "an exec that did not answer may have left the run going")
    }

    /// Each result line of the guest script as a `link machine update` answer.
    @Test func resultLinesMapToAnswers() {
        func code(_ stdout: String, exit: Int = 0) -> String? {
            let answer = CloudLegacyMachineUpdate.answer(CloudExecResult(exitCode: exit, stdout: stdout, stderr: "sudo: a password is required"), pin: Self.pin)
            return answer.ok ? (answer.updated ? "updated:\(answer.build ?? "")" : "current") : answer.errorCode
        }
        #expect(code("OK already-current daemon=9\n") == "updated:\(Self.pin.commit)")
        #expect(code("UNVERIFIED terminal count unavailable terminals=?->2 daemon=9\n") == "updated:\(Self.pin.commit)")
        #expect(code("ROLLBACK lost-hosts=[12] old-daemon=7\n") == "machine_update_rolled_back")
        #expect(code("FAIL rollback-daemon-unhealthy reason=x\n") == "machine_update_failed")
        #expect(code("SKIP busy another upgrade run holds the lock\n") == "machine_update_busy")
        #expect(code("SKIP no-daemon\n") == "machine_unreachable")
        #expect(code("SKIP unsupported-cloud-auth\n") == "machine_update_unsupported")
        #expect(code("SKIP disk-free=120MB\n") == "machine_update_failed")
        #expect(code("NOROOT\n") == "machine_update_unsupported", "an account that cannot become root")
        #expect(code("running\n") == "machine_update_unresolved")
        #expect(code("") == "machine_update_unresolved")
        #expect(code("", exit: 1) == "machine_update_failed", "the command stopped before the run")
    }

    /// The pin is the app bundle's own manifest; anything that is not plain hex is refused.
    @Test func thePinComesFromTheBundledManifestOnly() throws {
        let sha = String(repeating: "C", count: 64)
        let good = Data(#"{"commit":"\#(String(repeating: "d", count: 40))","binaries":{"cmux-tui-x86_64-unknown-linux-musl":"\#(sha)","cmux-tui-aarch64-unknown-linux-musl":"x"}}"#.utf8)
        #expect(CloudLegacyMachineUpdate.pin(manifest: good) == CloudLegacyMachineUpdate.Pin(commit: String(repeating: "d", count: 40), sha256: sha.lowercased()))
        #expect(CloudLegacyMachineUpdate.pin(manifest: Data(#"{"commit":"d; rm -rf /","binaries":{"cmux-tui-x86_64-unknown-linux-musl":"\#(sha)"}}"#.utf8)) == nil)
        #expect(CloudLegacyMachineUpdate.pin(manifest: Data(#"{"commit":"\#(String(repeating: "d", count: 40))","binaries":{}}"#.utf8)) == nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-pin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("cmux-tui-ssh"), withIntermediateDirectories: true)
        try good.write(to: folder.appendingPathComponent("cmux-tui-ssh/manifest.json"))
        #expect(CloudLegacyMachineUpdate.pin(besideCLI: folder.appendingPathComponent("cmux"))?.sha256 == sha.lowercased())
        #expect(CloudLegacyMachineUpdate.pin(besideCLI: folder.appendingPathComponent("missing/cmux")) == nil, "a dev build has no pin")
    }

    /// The app runs the fleet's own guest script, byte for byte (web/tests checks the other side).
    @Test func theGuestScriptIsTheFleetScript() throws {
        // Tests/CmuxNextAppTests/<file> in Packages/macOS/CmuxNext: six levels up is the repo.
        let repo = (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let fleet = try String(contentsOf: repo.appendingPathComponent("web/scripts/cloud-vm/cmux-tui-upgrade.sh"), encoding: .utf8)
        #expect(CloudLegacyMachineUpdate.script == fleet)
    }
}

/// Records each exec and answers `stdout`.
nonisolated final class ExecRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, Int)] = []
    private let stdout: String

    init(stdout: String) { self.stdout = stdout }

    var only: (String, Int)? { lock.withLock { calls.count == 1 ? calls[0] : nil } }

    var exec: @Sendable (String, Int) async throws -> CloudExecResult {
        { command, timeout in
            self.lock.withLock { self.calls.append((command, timeout)) }
            return CloudExecResult(exitCode: 0, stdout: self.stdout, stderr: "")
        }
    }
}
