@testable import CmuxNextApp
@testable import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// cmux-platform#89, part 2: a Worker machine (the Cloud app server link) has no `/api/vm` row, so
/// `cmux cloud deliver-secrets`, `apply-machine-config` and credential recovery failed at their
/// first read ("This machine has no finished machine config yet"). Its exec and file routes are the
/// same requests under `/v1/cloud/machines/{id}/` on the cmux API Worker, with the person's Stack
/// session and the team in `x-cmux-team`: a Mac install has no execute grant (backend
/// domains/user.ts), so the route's caller check (cloud-client-session.ts) refuses its token with a 403.
/// Which route and headers each client sends is cmux-tui's (`cli/cloud_api/tests.rs`); this checks
/// what each client hands it.
@Suite(.serialized)
struct CloudWorkerMachineFilesTests {
    /// One answer every machine call decodes: an exec's result and a read's contents.
    static let answer = #"{"ok":true,"body":{"exitCode":0,"stdout":"ok","stderr":"","path":"/a","dataBase64":"aGk=","size":2}}"#

    @Test func execAndFilesGoAsTheWorkerClientWithThePersonsSessionAndCmuxTeam() async throws {
        let cmux = try FakeBundledCmux(answer: Self.answer)
        defer { cmux.remove() }
        // A flow that pins the app's (Stack) team keeps the cmux team the Worker knows.
        let api = cmux.worker().pinningTeam("stack-team-1")
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa"
        #expect(try await api.exec(machine, command: "true", timeoutMs: 8_000).stdout == "ok")
        #expect(try await api.readFile(machine, path: "/home/cmux/.cmux/machine-config/status.json").dataBase64 == "aGk=")
        try await api.writeFile(machine, path: "/a", data: Data("hi".utf8), mode: 0o644)
        #expect(cmux.calls == ["machine.io exec", "machine.io read", "machine.io write"])
        for run in 1...3 {
            let request = cmux.request(run)
            // A Mac install token here is a 403 for every Mac user: its grant has no execute.
            #expect(request["credential"] as? String == "session-access")
            #expect(request["team"] as? String == "team_cmux")
            #expect(request["auth"] as? String == "worker")
            #expect(request["refresh"] == nil, "the Stack refresh token never goes to the Worker")
            #expect(request["api"] as? String == "https://machines.standin.invalid")
        }
        #expect((cmux.request(1)["args"] as? [String: Any])?["timeout_ms"] as? Int == 8_000)
    }

    /// Set Up GitHub's script runs on the Worker exec route, as `cmux`: a NEXT machine id is a Worker
    /// id, which classic `/api/vm/{id}/exec` does not know.
    @Test func gitHubSetupExecsOnTheWorkerRoute() async throws {
        let cmux = try FakeBundledCmux(answer: Self.answer)
        defer { cmux.remove() }
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", identity = CloudGitHubSetup.GitIdentity(name: "Ann", email: "ann@example.test")
        let outcome = try await CloudGitHubSetup.run(identity, app: true, machine: machine, on: cmux.worker())
        #expect(outcome == CloudGitHubSetup.parse(exitCode: 0, stdout: "ok"))
        #expect(cmux.calls == ["machine.io exec"])
        let args = try #require(cmux.request(1)["args"] as? [String: Any])
        #expect(args["command"] as? String == CloudGitHubSetup.command(identity, app: true))
        #expect(args["timeout_ms"] as? Int == CloudGitHubSetup.timeoutMs)
        #expect(args["machine"] as? String == machine)
    }

    @Test func theClassicClientKeepsItsSessionAndTeam() async throws {
        let cmux = try FakeBundledCmux(answer: Self.answer)
        defer { cmux.remove() }
        _ = try await cmux.classic().exec("m1", command: "true")
        let request = cmux.request(1)
        #expect(request["auth"] as? String == "stack")
        #expect(request["credential"] as? String == "access")
        #expect(request["refresh"] as? String == "refresh")
        #expect(request["team"] as? String == "team-1")
        #expect((request["args"] as? [String: Any])?["cache_dir"] == nil)
    }

    /// The Codex broker on a Worker machine asks its link's owner answer, never `/api/vm`'s attach
    /// answer or record (a Worker machine has no row there).
    @Test func theCodexBrokerOnAWorkerMachineNeverAsksTheClassicRoutes() async throws {
        let cmux = try FakeBundledCmux(answer: Self.answer)
        defer { cmux.remove() }
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", scope = CloudCodexBrokerScope(userID: "u1", teamID: "team-1")
        let refused = CloudCodexBrokerTarget(api: cmux.worker(), machineID: machine, scope: scope,
                                             callerOwnsVM: { false }, isLive: { true })
        #expect(try await refused.capability().ownerVM == false)
        #expect(try await refused.isLive())
        #expect(cmux.runs == 0)

        let owned = CloudCodexBrokerTarget(api: cmux.worker(), machineID: machine, scope: scope,
                                           callerOwnsVM: { true }, isLive: { true })
        #expect(try await owned.capability().ownerVM)
        #expect(cmux.calls == ["machine.io exec"])
        #expect(cmux.request(1)["auth"] as? String == "worker")
    }

    /// Claude credential recovery on a Worker machine: its exec runs as `cmux`, so a root 0600
    /// staging file (what the file route writes) can't be read by the installer, and every transfer
    /// failed. The folder is made `cmux`'s own 0700 one first, and the file goes in 0644.
    @Test func aWorkerMachineStagesTheCredentialWhereTheWorkUserCanReadIt() async throws {
        let cmux = try FakeBundledCmux(answer: Self.answer)
        defer { cmux.remove() }
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", path = "/home/cmux/.cmux/credential-transfer/x.json"
        try await CloudCredentialTransfer.stage(Data("tok".utf8), at: path, on: cmux.worker(), machineID: machine)
        #expect(cmux.calls == ["machine.io exec", "machine.io write"])
        let made = try #require((cmux.request(1)["args"] as? [String: Any])?["command"] as? String)
        #expect(made.contains("mkdir -p -- '/home/cmux/.cmux/credential-transfer'"))
        #expect(made.contains("chmod 700") && made.contains("test -O"))
        let write = try #require(cmux.request(2)["args"] as? [String: Any])
        #expect(write["mode"] as? Int == 0o644)
        #expect(write["path"] as? String == path)

        // The classic route keeps its root 0600 file (its exec is root, the installer chowns it).
        let classic = try FakeBundledCmux(answer: Self.answer)
        defer { classic.remove() }
        try await CloudCredentialTransfer.stage(Data("tok".utf8), at: path, on: classic.classic(), machineID: "m1")
        #expect(classic.calls == ["machine.io write"])
        #expect((classic.request(1)["args"] as? [String: Any])?["mode"] as? Int == 0o600)
    }
}
