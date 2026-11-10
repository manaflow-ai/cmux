@testable import CmuxNextApp
@testable import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// cmux-platform#89, part 2: a Worker machine (the Cloud app server link) has no `/api/vm` row. Its
/// exec and file calls are the daemon's `cloud.machine.io` (cmux-cloud-api `machine_io`), as the
/// person's Stack session and the cmux team: a Mac install has no execute grant (backend
/// domains/user.ts), so the route's caller check (cloud-client-session.ts) refuses its token with a 403.
struct CloudWorkerMachineFilesTests {
    private static let origin = URL(string: "https://machines.standin.invalid") ?? URL(fileURLWithPath: "/dev/null")

    private func fake() -> CloudDaemonFake {
        CloudDaemonFake { _, args in
            CloudDaemonFake.value(switch args["op"] as? String {
            case "exec": #"{"exitCode":0,"stdout":"ok","stderr":""}"#
            case "read": #"{"path":"/a","dataBase64":"aGk=","size":2}"#
            default: #"{"ok":true,"path":"/a"}"#
            })
        }
    }

    private func worker(_ fake: CloudDaemonFake) -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: Self.origin, accessToken: { "session-access" }, teamID: { "team_cmux" }, daemon: fake.daemon)
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
    /// failed. The folder is made `cmux`'s own 0700 one first, and the file goes in 0644.
    @Test func aWorkerMachineStagesTheCredentialWhereTheWorkUserCanReadIt() async throws {
        let fake = fake()
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", path = "/home/cmux/.cmux/credential-transfer/x.json"
        try await CloudCredentialTransfer.stage(Data("tok".utf8), at: path, on: worker(fake), machineID: machine)
        #expect(fake.sent.map { $0.args["op"] as? String } == ["exec", "write"])
        let made = try #require(fake.sent.first?.args["command"] as? String)
        #expect(made.contains("mkdir -p -- '/home/cmux/.cmux/credential-transfer'"))
        #expect(made.contains("chmod 700") && made.contains("test -O"))
        #expect(fake.sent.last?.args["mode"] as? Int == 0o644)
        #expect(fake.sent.last?.args["path"] as? String == path)
    }
}
