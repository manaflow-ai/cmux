@testable import CmuxNextApp
@testable import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import CmuxNextDaemon
import Foundation
import Testing

/// cmux-platform#89, part 2: a Worker machine (the Cloud app server link) has no `/api/vm` row, so
/// `cmux cloud deliver-secrets`, `apply-machine-config` and credential recovery failed at their
/// first read ("This machine has no finished machine config yet"). Its exec and file routes are the
/// same requests under `/v1/cloud/machines/{id}/` on the cmux API Worker, with the person's Stack
/// session and the team in `x-cmux-team`: a Mac install has no execute grant (backend
/// domains/user.ts), so the route's caller check (cloud-client-session.ts) refuses its token with a 403.
/// The calls are the daemon's `cloud.machine.io` (cmux-cloud-api `machine.rs` picks the route and headers).
@Suite struct CloudWorkerMachineFilesTests {
    static func api() -> FakeCloudAPI {
        FakeCloudAPI { call in
            switch call.args["op"]?.stringValue {
            case "exec": FakeCloudAPI.json(#"{"exitCode":0,"stdout":"ok","stderr":""}"#)
            case "read": FakeCloudAPI.json(#"{"path":"/a","dataBase64":"aGk=","size":2}"#)
            default: FakeCloudAPI.json(#"{"ok":true,"path":"/a"}"#)
            }
        }
    }

    @Test func execAndFilesGoAsTheWorkerWithThePersonsSessionAndCmuxTeam() async throws {
        let fake = Self.api()
        // A flow that pins the app's (Stack) team keeps the cmux team the Worker knows.
        let api = fake.worker().pinningTeam("stack-team-1")
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa"
        #expect(try await api.exec(machine, command: "true", timeoutMs: 8_000).stdout == "ok")
        #expect(try await api.readFile(machine, path: "/home/cmux/.cmux/machine-config/status.json").dataBase64 == "aGk=")
        try await api.writeFile(machine, path: "/a", data: Data("hi".utf8), mode: 0o644)
        #expect(fake.operations == ["cloud.machine.io", "cloud.machine.io", "cloud.machine.io"])
        #expect(fake.seen.map { $0.args["op"]?.stringValue } == ["exec", "read", "write"])
        #expect(fake.seen[0].args["timeout_ms"]?.intValue == 8_000)
        #expect(fake.seen[1].args["path"]?.stringValue == "/home/cmux/.cmux/machine-config/status.json")
        #expect(fake.seen[2].args["data_base64"]?.stringValue == "aGk=")
        #expect(fake.seen[2].args["mode"]?.intValue == 0o644)
        for call in fake.seen {
            // A Mac install token here is a 403 for every Mac user: its grant has no execute.
            #expect(call.field("auth") == "worker")
            #expect(call.field("api") == "https://machines.standin.invalid")
            #expect(call.field("access_token") == "session-access")
            #expect(call.field("team") == "team_cmux")
            #expect(call.fields["refresh_token"] == nil, "the Stack refresh token never goes to the Worker")
            #expect(call.args["machine"]?.stringValue == machine)
        }
    }

    /// Set Up GitHub's script runs on the Worker exec route, as `cmux`: a NEXT machine id is a Worker
    /// id, which classic `/api/vm/{id}/exec` does not know.
    @Test func gitHubSetupExecsOnTheWorkerRoute() async throws {
        let fake = Self.api()
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", identity = CloudGitHubSetup.GitIdentity(name: "Ann", email: "ann@example.test")
        let outcome = try await CloudGitHubSetup.run(identity, app: true, machine: machine, on: fake.worker())
        #expect(outcome == CloudGitHubSetup.parse(exitCode: 0, stdout: "ok"))
        #expect(fake.seen.map(\.operation) == ["cloud.machine.io"])
        #expect(fake.seen.first?.field("auth") == "worker")
        #expect(fake.seen.first?.args["command"]?.stringValue == CloudGitHubSetup.command(identity, app: true))
        #expect(fake.seen.first?.args["timeout_ms"]?.intValue == CloudGitHubSetup.timeoutMs)
    }

    @Test func theClassicClientGoesAsStackWithItsRefreshTokenAndTeam() async throws {
        let fake = Self.api()
        _ = try await fake.classic().exec("m1", command: "true")
        let call = try #require(fake.seen.first)
        #expect(call.operation == "cloud.machine.io")
        #expect(call.field("auth") == "stack")
        #expect(call.field("api") == "https://vm-api.standin.invalid")
        #expect(call.field("access_token") == "access")
        #expect(call.field("refresh_token") == "refresh")
        #expect(call.field("team") == "team-1")
        #expect(call.args["machine"]?.stringValue == "m1")
    }

    @Test func aWorkerRefusalNamesItsNestedCodeAndMessage() {
        let body = Data(#"{"ok":false,"error":{"code":"vm_not_running","message":"Start the machine first."}}"#.utf8)
        #expect(CloudAPIError.from(status: 409, data: body, headerCode: nil)
            == .http(status: 409, code: "vm_not_running", message: "Start the machine first.", action: nil, traceId: nil))
        #expect(CloudAPIError.from(status: 409, data: body, headerCode: "vm_not_running")
            == .http(status: 409, code: "vm_not_running", message: "Start the machine first.", action: nil, traceId: nil))
    }

    /// Claude credential recovery on a Worker machine: its exec runs as `cmux`, so a root 0600
    /// staging file (what the file route writes) can't be read by the installer, and every transfer
    /// failed. The folder is made `cmux`'s own 0700 one first, and the file goes in 0644.
    @Test func aWorkerMachineStagesTheCredentialWhereTheWorkUserCanReadIt() async throws {
        let fake = Self.api()
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", path = "/home/cmux/.cmux/credential-transfer/x.json"
        try await CloudCredentialTransfer.stage(Data("tok".utf8), at: path, on: fake.worker(), machineID: machine)
        #expect(fake.seen.map { $0.args["op"]?.stringValue } == ["exec", "write"])
        let made = try #require(fake.seen.first?.args["command"]?.stringValue)
        #expect(made.contains("mkdir -p -- '/home/cmux/.cmux/credential-transfer'"))
        #expect(made.contains("chmod 700") && made.contains("test -O"))
        #expect(fake.seen.last?.args["mode"]?.intValue == 0o644)
        #expect(fake.seen.last?.args["path"]?.stringValue == path)

        // The classic route keeps its root 0600 file (its exec is root, the installer chowns it).
        let classicFake = Self.api()
        try await CloudCredentialTransfer.stage(Data("tok".utf8), at: path, on: classicFake.classic(), machineID: "m1")
        #expect(classicFake.seen.map { $0.args["op"]?.stringValue } == ["write"])
        #expect(classicFake.seen.first?.field("auth") == "stack")
        #expect(classicFake.seen.first?.args["mode"]?.intValue == 0o600)
    }
}
