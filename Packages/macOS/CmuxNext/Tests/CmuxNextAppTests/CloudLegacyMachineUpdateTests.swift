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

    /// One exec starts the run, detached as root with the pinned install and the guest script;
    /// later ones wait on it, each within the provider's 5-minute exec. A wait the provider ended
    /// (exit 124) or one before the result is followed by the next; the result line is the answer.
    @Test func theRunStartsDetachedThenWaitsForItsResult() async throws {
        let calls = ExecRecorder(answers: [
            CloudExecResult(exitCode: 0, stdout: "started\n", stderr: ""),
            CloudExecResult(exitCode: 124, stdout: "", stderr: "cmux: the command did not exit within 290s; it may still be running"),
            CloudExecResult(exitCode: 0, stdout: "running\n", stderr: ""),
            CloudExecResult(exitCode: 0, stdout: "OK upgraded terminals=3->3 daemon=812 hosts-before=3\n", stderr: ""),
        ])
        let answer = await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "echo guest\n", nonce: "0123456789abcdef", exec: calls.exec)

        #expect(answer == CloudMoveCLI.Answer(ok: true, updated: true, build: Self.pin.commit))
        let made = calls.calls
        #expect(made.map(\.1) == [60_000, 290_000, 290_000, 290_000], "each exec within the provider's 5 minutes")
        let start = try #require(made.first?.0)
        #expect(start.contains(#"r="$d/app-0123456789abcdef""#))
        #expect(start.contains(Data(CloudLegacyMachineUpdate.installCommand(Self.pin).utf8).base64EncodedString()))
        #expect(start.contains(Data("echo guest\n".utf8).base64EncodedString()))
        #expect(start.contains("systemd-run --quiet --collect --unit=cmux-app-tui-update-0123456789abcdef /bin/sh \"$r/upgrade.sh\" \(Self.pin.sha256) \(Self.pin.commit) \"$r\""))
        #expect(!start.contains("--wait"), "the start exec waits for nothing")
        #expect(Set(made.dropFirst().map(\.0)) == [CloudLegacyMachineUpdate.waitCommand(nonce: "0123456789abcdef")])
        let install = CloudLegacyMachineUpdate.installCommand(Self.pin)
        #expect(install.contains("'https://files.cmux.com/cmux-tui/\(Self.pin.commit)/cmux-tui-x86_64-unknown-linux-musl'"))
        #expect(install.contains("printf '%s  %s\\n' \(Self.pin.sha256) \"$tmp\" | sha256sum -c"), "the download is checked against the pin")
    }

    /// A start that did not answer may have started the run, and a run past every wait goes on:
    /// both are unresolved (asked again later). A start from an account that cannot become root
    /// changed nothing: the machine cannot update this way.
    @Test func aStartOrRunWithNoOutcomeIsUnresolved() async {
        let lost = await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "", exec: { _, _ in throw CloudAPIError.timedOut("exec") })
        #expect(lost.errorCode == "machine_update_unresolved")

        let long = ExecRecorder(answers: [CloudExecResult(exitCode: 0, stdout: "started\n", stderr: "")]
            + Array(repeating: CloudExecResult(exitCode: 0, stdout: "running\n", stderr: ""), count: 3))
        let running = await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "", waits: 3, exec: long.exec)
        #expect(running.errorCode == "machine_update_unresolved")
        #expect(long.calls.count == 4)

        let noRoot = ExecRecorder(answers: [CloudExecResult(exitCode: 0, stdout: "NOROOT\n", stderr: "")])
        #expect(await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "", exec: noRoot.exec).errorCode == "machine_update_unsupported")
        #expect(noRoot.calls.count == 1)
    }

    /// A start the provider ended (exit 124, no output) may have started the run: the waits read
    /// its outcome. A start that ended on its own without `started` started nothing: one wait
    /// reads the empty run, and it is a failure with what the start said.
    @Test func aStartTheProviderEndedIsWaitedOnAndARefusedOneFails() async {
        let ended = ExecRecorder(answers: [
            CloudExecResult(exitCode: 124, stdout: "", stderr: "the command did not exit within 60s; it may still be running"),
            CloudExecResult(exitCode: 0, stdout: "ROLLBACK lost-hosts=[12] old-daemon=7\n", stderr: ""),
        ])
        #expect(await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "", exec: ended.exec).errorCode == "machine_update_rolled_back")

        let refused = ExecRecorder(answers: [
            CloudExecResult(exitCode: 1, stdout: "", stderr: "base64: invalid input"),
            CloudExecResult(exitCode: 0, stdout: "\n", stderr: ""),
        ])
        let answer = await CloudLegacyMachineUpdate.run(pin: Self.pin, script: "", exec: refused.exec)
        #expect(answer.errorCode == "machine_update_failed")
        #expect(answer.error == "base64: invalid input")
        #expect(refused.calls.count == 2, "one wait for a run that never began")
    }

    /// The exec path runs only for the build this app pins: another build's manifest is not this
    /// app's to install.
    @Test func theExecPathRunsOnlyForThePinnedBuild() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-build-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("cmux-tui-ssh"), withIntermediateDirectories: true)
        let manifest = #"{"commit":"\#(Self.pin.commit)","binaries":{"cmux-tui-x86_64-unknown-linux-musl":"\#(Self.pin.sha256)"}}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("cmux-tui-ssh/manifest.json"))
        let cli = folder.appendingPathComponent("cmux")
        #expect(CloudLegacyMachineUpdate.pin(for: String(Self.pin.commit.prefix(12)), besideCLI: cli) == Self.pin)
        #expect(CloudLegacyMachineUpdate.pin(for: String(repeating: "c", count: 12), besideCLI: cli) == nil)
    }

    /// The start and wait commands run for real under /bin/sh, with stand-ins for sudo, systemd
    /// and the guest script: through a systemd unit, and under setsid when the unit does not start.
    /// The run gets the pin's digest, commit and directory, its outcome is the answer, and the run
    /// takes its files and the old binary's backup with it.
    @Test(arguments: [true, false]) func theCommandsRunTheGuestScriptToItsResult(systemd: Bool) async throws {
        let shell = try ShellMachine(systemd: systemd)
        defer { shell.remove() }
        let guest = #"""
            echo running > "$3/result"; echo "$1 $2 $3" > "$3/args"; touch "$3/cmux-tui.prev"
            sleep 1
            echo "OK upgraded terminals=2->2 daemon=99 hosts-before=2" > "$3/result"
            """#
        let answer = await CloudLegacyMachineUpdate.run(pin: Self.pin, script: guest, nonce: "feedfacecafebeef", directory: shell.directory.path,
                                                        waitSeconds: 20, exec: shell.exec)

        #expect(answer == CloudMoveCLI.Answer(ok: true, updated: true, build: Self.pin.commit))
        let run = shell.directory.appendingPathComponent("app-feedfacecafebeef")
        #expect(try String(contentsOf: run.appendingPathComponent("args"), encoding: .utf8)
            == "\(Self.pin.sha256) \(Self.pin.commit) \(run.path)\n")
        for gone in ["install.cmd", "upgrade.sh", "cmux-tui.prev"] {
            #expect(!FileManager.default.fileExists(atPath: run.appendingPathComponent(gone).path), "\(gone) left behind")
        }
        #expect(shell.unitStarted == systemd)
    }

    /// Each result line of the guest script as a `link machine update` answer.
    @Test func resultLinesMapToAnswers() {
        func code(_ stdout: String, exit: Int = 0) -> String? {
            let answer = CloudLegacyMachineUpdate.answer(CloudExecResult(exitCode: exit, stdout: stdout, stderr: "sudo: a password is required"), pin: Self.pin)
            return answer.ok ? (answer.updated ? "updated:\(answer.build ?? "")" : "current") : answer.errorCode
        }
        #expect(code("OK already-current daemon=9\n") == "current", "nothing restarted")
        #expect(code("OK canary daemon=9 hosts-before=1\n") == "updated:\(Self.pin.commit)")
        #expect(code("UNVERIFIED terminal count unavailable terminals=?->2 daemon=9\n") == "updated:\(Self.pin.commit)")
        #expect(code("ROLLBACK lost-hosts=[12] old-daemon=7\n") == "machine_update_rolled_back")
        #expect(code("FAIL rollback-daemon-unhealthy reason=x\n") == "machine_update_failed")
        #expect(code("SKIP busy another upgrade run holds the lock\n") == "machine_update_busy")
        #expect(code("SKIP no-daemon\n") == "machine_unreachable")
        #expect(code("SKIP unsupported-cloud-auth\n") == "machine_update_unsupported")
        #expect(code("SKIP disk-free=120MB\n") == "machine_update_busy", "nothing changed: asked again, not a failure kept for the build")
        #expect(code("NOROOT\n") == "machine_update_unsupported", "an account that cannot become root")
        #expect(code("running\n") == "machine_update_unresolved")
        #expect(code("") == "machine_update_unresolved")
        #expect(code("", exit: 124) == "machine_update_unresolved", "the provider ended the wait; the run may go on")
        #expect(code("garbage", exit: 124) == "machine_update_unresolved")
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

/// Records each exec and answers the next of `answers` (the last again once they run out).
nonisolated final class ExecRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(String, Int)] = []
    private let answers: [CloudExecResult]

    init(answers: [CloudExecResult]) { self.answers = answers }

    var calls: [(String, Int)] { lock.withLock { made } }

    var exec: CloudLegacyMachineUpdate.Exec {
        { command, timeout in
            self.lock.withLock {
                self.made.append((command, timeout))
                return self.answers[min(self.made.count, self.answers.count) - 1]
            }
        }
    }
}

/// A machine for the exec commands: /bin/sh with stand-ins on PATH for sudo (runs the command),
/// systemd-run (starts it in the background and keeps its pid for systemctl; with `systemd`
/// false it fails to start, as without systemd), setsid, nohup, timeout and `tail --pid`.
nonisolated final class ShellMachine: @unchecked Sendable {
    let root: URL
    var directory: URL { root.appendingPathComponent("upgrade") }
    private var stubs: URL { root.appendingPathComponent("bin") }
    var unitStarted: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("mainpid").path) }

    init(systemd: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("upgrade"), withIntermediateDirectories: true)
        let state = root.path
        let scripts = [
            "sudo": #"[ "$1" = -n ] && shift; exec "$@""#,
            "systemd-run": systemd
                ? #"while [ "${1#--}" != "$1" ]; do shift; done; nohup "$@" >/dev/null 2>&1 & echo $! > "\#(state)/mainpid""#
                : "exit 1",
            "systemctl": #"cat "\#(state)/mainpid""#,
            "setsid": #"exec "$@""#,
            // macOS's nohup refuses to run outside a login session (a CI runner's): the machine's does not.
            "nohup": #"exec "$@""#,
            "timeout": #"shift; exec "$@""#,
            "tail": #"case "$1" in --pid=*) p=${1#--pid=}; while kill -0 "$p" 2>/dev/null; do sleep 0.1; done ;; *) exec /usr/bin/tail "$@" ;; esac"#,
        ]
        for (name, body) in scripts {
            let file = stubs.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    var exec: CloudLegacyMachineUpdate.Exec {
        let path = "\(stubs.path):/usr/bin:/bin:/usr/sbin:/sbin"
        return { command, _ in try await Self.sh(command, path: path) }
    }

    @concurrent private static func sh(_ command: String, path: String) async throws -> CloudExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": path, "HOME": NSTemporaryDirectory()]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CloudExecResult(exitCode: Int(process.terminationStatus), stdout: String(decoding: stdout, as: UTF8.self),
                               stderr: String(decoding: stderr, as: UTF8.self))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
