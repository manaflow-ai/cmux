@testable import CmuxNextApp
@testable import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// cmux-platform#89, part 2: a Worker machine (the Cloud app server link) has no `/api/vm` row. Its
/// exec and file calls are the daemon's `cloud.machine.io` (cmux-cloud-api `machine_io`), as the
/// person's Stack session and the cmux team: a Mac install has no execute grant (backend
/// domains/user.ts), so the route's caller check (cloud-client-session.ts) refuses its token with a 403.
struct CloudWorkerMachineFilesTests {
    /// The client's blocking-work lanes: every transfer file's disk work runs on its files lane.
    let work = BackgroundWork()
    private static let origin = URL(string: "https://machines.standin.invalid") ?? URL(fileURLWithPath: "/dev/null")

    private func fake() -> CloudDaemonFake {
        CloudDaemonFake { _, args in
            switch args["op"] as? String {
            case "exec":
                return CloudDaemonFake.value(#"{"exitCode":0,"stdout":"ok","stderr":""}"#)
            case "read":
                // The daemon fills the read's file (the path form) and answers its metadata.
                if let local = args["local_path"] as? String { FileManager.default.createFile(atPath: local, contents: Data("hi".utf8)) }
                return CloudDaemonFake.value(#"{"path":"/a","size":2}"#)
            default:
                return CloudDaemonFake.value(#"{"ok":true,"path":"/a"}"#)
            }
        }
    }

    private func worker(_ fake: CloudDaemonFake) -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: Self.origin, accessToken: { "session-access" }, teamID: { "team_cmux" }, daemon: fake.daemon, work: work)
    }

    @Test func execAndFilesGoToTheWorkerRoutesWithThePersonsSessionAndCmuxTeam() async throws {
        let fake = fake()
        // A flow that pins the app's (Stack) team keeps the cmux team the Worker knows.
        let api = worker(fake).pinningTeam("stack-team-1")
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa"
        #expect(try await api.exec(machine, command: "true", timeoutMs: 8_000).stdout == "ok")
        #expect(try await api.readFile(machine, path: "/home/cmux/.cmux/machine-config/status.json").dataBase64 == "aGk=")
        try await api.writeFile(machine, path: "/a", data: Data("hi".utf8), mode: 0o644)
        #expect(fake.sent.map(\.operation) == ["cloud.machine.io", "cloud.machine.io", "cloud.machine.io"])
        #expect(fake.sent.map { $0.args["op"] as? String } == ["exec", "read", "write"])
        #expect(fake.sent.first?.args["timeout_ms"] as? Int == 8_000)
        #expect(fake.sent[1].args["path"] as? String == "/home/cmux/.cmux/machine-config/status.json")
        #expect(fake.sent[2].args["data_base64"] as? String == "aGk=" && fake.sent[2].args["mode"] as? Int == 0o644)
        for sent in fake.sent {
            // A Mac install token here is a 403 for every Mac user: its grant has no execute.
            #expect(sent.args["machine"] as? String == machine)
            #expect(sent.params["api"] as? String == "https://machines.standin.invalid")
            #expect(sent.params["auth"] as? String == "worker" && sent.params["access_token"] as? String == "session-access")
            #expect(sent.params["team"] as? String == "team_cmux")
            #expect(sent.params["refresh_token"] == nil, "the Stack refresh token never goes to the Worker")
        }
    }

    /// Set Up GitHub's script runs on the Worker exec route, as `cmux`: a NEXT machine id is a Worker
    /// id, which classic `/api/vm/{id}/exec` does not know.
    @Test func gitHubSetupExecsOnTheWorkerRoute() async throws {
        let fake = fake()
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", identity = CloudGitHubSetup.GitIdentity(name: "Ann", email: "ann@example.test")
        let outcome = try await CloudGitHubSetup.run(identity, app: true, machine: machine, on: worker(fake))
        #expect(outcome == CloudGitHubSetup.parse(exitCode: 0, stdout: "ok"))
        #expect(fake.sent.map { $0.args["op"] as? String } == ["exec"])
        #expect(fake.sent.first?.args["command"] as? String == CloudGitHubSetup.command(identity, app: true))
        #expect(fake.sent.first?.args["timeout_ms"] as? Int == CloudGitHubSetup.timeoutMs)
    }

    /// Classic `/api/vm` is gone from NEXT: the sign-in client refuses a machine call before any call.
    @Test func theSignInClientRefusesMachineCallsBeforeAnyRequest() async throws {
        let fake = fake()
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" }, daemon: fake.daemon)
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.unsupported", message: nil)) {
            _ = try await api.exec("m1", command: "true")
        }
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.unsupported", message: nil)) {
            try await api.writeFile("m1", path: "/tmp/x", data: Data("x".utf8))
        }
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.unsupported", message: nil)) {
            _ = try await api.prepareSCP("m1", publicKey: "ssh-ed25519 AAAA")
        }
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)) {
            _ = try await api.createPreviewShareLink("m1", port: 3000)
        }
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)) {
            _ = try await api.revokePreviewShareLink("m1", port: 3000, linkID: "link_1")
        }
        #expect(fake.sent.isEmpty)
    }

    /// Claude credential recovery on a Worker machine: its exec runs as `cmux`, so a root 0600
    /// staging file (what the file route writes) can't be read by the installer, and every transfer
    /// failed. The file goes in 0644 into `cmux`'s own 0700 folder, which the guest check that passed
    /// just before made and checked (no symlink, `cmux`'s): the stage itself is one write, no exec.
    @Test func aWorkerMachineStagesTheCredentialWhereTheWorkUserCanReadIt() async throws {
        let fake = fake()
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", path = "/home/cmux/.cmux/credential-transfer/x.json"
        try await CloudCredentialTransfer.stage(Data("tok".utf8), at: path, on: worker(fake), machineID: machine)
        #expect(fake.sent.map { $0.args["op"] as? String } == ["write"])
        #expect(fake.sent.last?.args["mode"] as? Int == 0o644)
        #expect(fake.sent.last?.args["path"] as? String == path)
        for check in [CloudCredentialInstaller.preflight, CloudCredentialInstaller.creatorTeamPreflight] {
            #expect(check.contains("mkdir -p /home/cmux/.cmux/credential-transfer") && check.contains("chmod 700 /home/cmux/.cmux/credential-transfer"))
            #expect(check.contains("[ ! -L /home/cmux/.cmux/credential-transfer ]") && check.contains("stat -c %U /home/cmux/.cmux/credential-transfer)\" = cmux"))
        }
    }

    /// A read's bytes come through a new name in the transfer folder, removed after the call.
    @Test func aReadComesThroughATransferFileThatIsRemovedAfterwards() async throws {
        let fake = fake()
        let contents = try await worker(fake).readFile("vm_aaaaaaaaaaaaaaaaaaaa", path: "/a")
        #expect(contents.data == Data("hi".utf8) && contents.size == 2)
        let local = try #require(fake.sent.first?.args["local_path"] as? String)
        let folder = try CloudTransferFile.folder().path
        #expect(URL(fileURLWithPath: local).deletingLastPathComponent().path == folder)
        #expect(!FileManager.default.fileExists(atPath: local))
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    /// A write past the inline limit hands the daemon a private file instead of base64 a protocol
    /// request (4 MiB) could not hold; a small one stays inline.
    @Test func aLargeWriteGoesThroughAPrivateTransferFile() async throws {
        final class Seen: Sendable { let file = Mutex<(bytes: Data?, mode: Int?)>((nil, nil)) }
        let seen = Seen()
        let fake = CloudDaemonFake { _, args in
            if let local = args["local_path"] as? String {
                let mode = (try? FileManager.default.attributesOfItem(atPath: local))?[.posixPermissions] as? Int
                let bytes = FileManager.default.contents(atPath: local)
                seen.file.withLock { $0 = (bytes, mode) }
            }
            return CloudDaemonFake.value(#"{"ok":true}"#)
        }
        let data = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try await worker(fake).writeFile("vm_aaaaaaaaaaaaaaaaaaaa", path: "/big", data: data, mode: 0o600)
        let args = try #require(fake.sent.first?.args)
        #expect(args["data_base64"] == nil && args["path"] as? String == "/big" && args["mode"] as? Int == 0o600)
        let local = try #require(args["local_path"] as? String)
        #expect(seen.file.withLock { $0.bytes } == data)
        #expect(seen.file.withLock { $0.mode } == 0o600)
        #expect(!FileManager.default.fileExists(atPath: local))

        try await worker(fake).writeFile("vm_aaaaaaaaaaaaaaaaaaaa", path: "/small", data: Data("hi".utf8))
        #expect(fake.sent.last?.args["data_base64"] as? String == "aGk=" && fake.sent.last?.args["local_path"] == nil)
    }

    /// The transfer folder is the one the daemon resolves (the per-user temp dir from confstr, not a
    /// `TMPDIR` override), and a transfer file goes only when both the caller and the call let it go:
    /// a cancelled caller lets go first, while the call may still use the file.
    @Test func aTransferFileOutlivesACancelledCallerUntilTheCallEnds() async throws {
        let folder = try CloudTransferFile.folder()
        #expect(folder.lastPathComponent == "cmux-cloud-transfer" && folder.path.hasPrefix("/var/folders/"))
        let file = try await CloudTransferFile.make(on: work)
        try await file.write(Data("x".utf8), on: work)
        await file.done(on: work)
        #expect(FileManager.default.fileExists(atPath: file.url.path), "the call still holds it")
        file.callEnded()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))

        let other = try await CloudTransferFile.make(on: work)
        try await other.write(Data("y".utf8), on: work)
        other.callEnded()
        #expect(FileManager.default.fileExists(atPath: other.url.path), "the caller still reads it")
        await other.done(on: work)
        #expect(!FileManager.default.fileExists(atPath: other.url.path))
    }

    /// Review of #40104 at bac760b8 (F2): a transfer file's disk work goes through the client's
    /// files lane, never Swift's cooperative pool. With those lanes shut down (no item starts), a
    /// large write and a read each end before any daemon call, again and again.
    @Test func transferFileDiskWorkRunsOnTheFilesLane() async throws {
        let fake = fake()
        let closed = BackgroundWork()
        await closed.shutdown()
        let client = CloudAPIClient.workerMachines(baseURL: Self.origin, accessToken: { "session-access" }, teamID: { "team_cmux" },
                                                   daemon: fake.daemon, work: closed)
        let large = Data(repeating: 7, count: CloudTransferFile.inlineLimit + 1)
        for _ in 0..<3 {
            await #expect(throws: CancellationError.self) {
                try await client.writeFile("vm_aaaaaaaaaaaaaaaaaaaa", path: "/big", data: large)
            }
            await #expect(throws: CancellationError.self) { try await client.readFile("vm_aaaaaaaaaaaaaaaaaaaa", path: "/a") }
        }
        #expect(fake.sent.isEmpty, "no daemon call went without its file")
        // A small write needs no file and no lane.
        try await client.writeFile("vm_aaaaaaaaaaaaaaaaaaaa", path: "/small", data: Data("hi".utf8))
        #expect(fake.sent.last?.args["data_base64"] as? String == "aGk=")
    }
}
