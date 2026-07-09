import Foundation
import Testing

@testable import CmuxHooks

@Suite
struct SpawnHookGateTests {
    @Test
    func absentAndDisabledProceedWithoutRunner() async throws {
        let request = sampleRequest()
        let absentRunner = FakeHookProcessRunner(scripts: [])
        let absentGate = SpawnHookGate(configState: { .absent }, runner: absentRunner, log: { _ in })
        #expect(await absentGate.evaluate(request) == .proceed(sampleGrant()))
        #expect(await absentRunner.recordedInvocations().isEmpty)

        let disabledRunner = FakeHookProcessRunner(scripts: [])
        let config = CmuxHooksConfig(preSpawn: try CmuxHookDefinition(command: "/bin/false", enabled: false))
        let disabledGate = SpawnHookGate(configState: { .loaded(config) }, runner: disabledRunner, log: { _ in })
        #expect(await disabledGate.evaluate(request) == .proceed(sampleGrant()))
        #expect(await disabledRunner.recordedInvocations().isEmpty)
    }

    @Test
    func brokenConfigDeniesWithoutRunner() async {
        let runner = FakeHookProcessRunner(scripts: [])
        let gate = SpawnHookGate(configState: { .broken(reason: "bad hooks") }, runner: runner, log: { _ in })
        let outcome = await gate.evaluate(sampleRequest())
        if case .deny(let reason) = outcome {
            #expect(reason.contains("bad hooks"))
        } else {
            Issue.record("expected denial")
        }
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test
    func allowAndStdinEchoRequest() async throws {
        let runner = FakeHookProcessRunner(scripts: [.immediate(.successJSON(#"{"decision":"allow"}"#))])
        let gate = SpawnHookGate(configState: { .loaded(try! config()) }, runner: runner, log: { _ in })
        #expect(await gate.evaluate(sampleRequest()) == .proceed(sampleGrant()))
        let invocation = try #require(await runner.recordedInvocations().first)
        let object = try JSONSerialization.jsonObject(with: invocation.stdin) as? [String: Any]
        let spawn = try #require(object?["spawn"] as? [String: Any])
        #expect(object?["hook"] as? String == "preSpawn")
        #expect(spawn["command"] as? String == "echo hi")
        #expect(spawn["workingDirectory"] as? String == "/tmp/work")
        #expect((spawn["environmentAdditions"] as? [String: String])?["A"] == "B")
        #expect(spawn["surfaceId"] as? String == "surface-1")
        #expect(spawn["workspaceId"] as? String == "workspace-1")
        #expect(spawn["source"] as? String == "normal")
        #expect(spawn["isRespawn"] as? Bool == true)
    }

    @Test(arguments: [
        (#"{"decision":"rewrite","command":"sbx -- echo hi"}"#, "sbx -- echo hi"),
        (#"{"decision":"rewrite"}"#, "echo hi"),
    ])
    func rewriteCommandSemantics(json: String, expectedCommand: String?) async throws {
        let runner = FakeHookProcessRunner(scripts: [.immediate(.successJSON(json))])
        let gate = SpawnHookGate(configState: { .loaded(try! config()) }, runner: runner, log: { _ in })
        #expect(await gate.evaluate(sampleRequest()) == .proceed(SpawnHookGrant(
            command: expectedCommand,
            workingDirectory: "/tmp/work",
            environmentOverrides: ["A": "B"]
        )))
    }

    @Test
    func rewriteExplicitNullCommandCwdAndEnv() async throws {
        let json = #"{"decision":"rewrite","command":null,"workingDirectory":"/x","env":{"A":"C","K":"V"}}"#
        let runner = FakeHookProcessRunner(scripts: [.immediate(.successJSON(json))])
        let gate = SpawnHookGate(configState: { .loaded(try! config()) }, runner: runner, log: { _ in })
        #expect(await gate.evaluate(sampleRequest()) == .proceed(SpawnHookGrant(
            command: nil,
            workingDirectory: "/x",
            environmentOverrides: ["A": "C", "K": "V"]
        )))
    }

    @Test
    func denyReasonDefaults() async throws {
        let runner = FakeHookProcessRunner(scripts: [.immediate(.successJSON(#"{"decision":"deny"}"#))])
        let gate = SpawnHookGate(configState: { .loaded(try! config()) }, runner: runner, log: { _ in })
        #expect(await gate.evaluate(sampleRequest()) == .deny(reason: "denied by pre-spawn hook"))
    }

    @Test(arguments: [
        HookProcessResult.failure(exitStatus: 2),
        HookProcessResult.failure(exitStatus: 0, stdout: Data("not json".utf8)),
        HookProcessResult.failure(exitStatus: nil, timedOut: true),
        HookProcessResult.launchFailure("missing"),
        HookProcessResult.failure(exitStatus: 0, stdout: Data(repeating: 65, count: 1_048_577)),
    ])
    func failClosedRunnerFailures(result: HookProcessResult) async throws {
        let runner = FakeHookProcessRunner(scripts: [.immediate(result)])
        let gate = SpawnHookGate(configState: { .loaded(try! config()) }, runner: runner, log: { _ in })
        if case .deny = await gate.evaluate(sampleRequest()) {} else {
            Issue.record("expected denial")
        }
    }

    @Test
    func realProcessAllow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hooks-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("allow.sh")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"decision":"rewrite","command":"real"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = CmuxHooksConfig(preSpawn: try CmuxHookDefinition(command: script.path, timeoutMs: 2_000))
        let gate = SpawnHookGate(configState: { .loaded(config) }, runner: HookProcessRunner(), log: { _ in })
        if case .proceed(let grant) = await gate.evaluate(sampleRequest()) {
            #expect(grant.command == "real")
        } else {
            Issue.record("expected proceed")
        }
    }

    @Test
    func realProcessTimeoutDeniesQuickly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hooks-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("sleep.sh")
        try "#!/bin/sh\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = CmuxHooksConfig(preSpawn: try CmuxHookDefinition(command: script.path, timeoutMs: 300))
        let gate = SpawnHookGate(configState: { .loaded(config) }, runner: HookProcessRunner(), log: { _ in })
        let result = try await completesWithin(seconds: 3) {
            await gate.evaluate(sampleRequest())
        }
        if case .deny = result {} else {
            Issue.record("expected timeout denial")
        }
    }

    private static func sampleRequest() -> SpawnHookRequest {
        SpawnHookRequest(
            command: "echo hi",
            workingDirectory: "/tmp/work",
            environmentAdditions: ["A": "B"],
            surfaceId: "surface-1",
            workspaceId: "workspace-1",
            source: "normal",
            isRespawn: true
        )
    }

    private static func sampleGrant() -> SpawnHookGrant {
        SpawnHookGrant(command: "echo hi", workingDirectory: "/tmp/work", environmentOverrides: ["A": "B"])
    }

    private static func config() throws -> CmuxHooksConfig {
        CmuxHooksConfig(preSpawn: try CmuxHookDefinition(command: "/bin/gate"))
    }

    private func sampleRequest() -> SpawnHookRequest {
        Self.sampleRequest()
    }

    private func sampleGrant() -> SpawnHookGrant {
        Self.sampleGrant()
    }

    private func config() throws -> CmuxHooksConfig {
        try Self.config()
    }
}
