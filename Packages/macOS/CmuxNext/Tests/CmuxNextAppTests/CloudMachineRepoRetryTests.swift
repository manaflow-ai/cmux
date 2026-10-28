@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

nonisolated struct CloudMachineRepoRetryTests {
    @Test(arguments: ["offline", "needs_github", "not_found", "failed"])
    func cloneFailuresHaveTypedReasonsWithoutPersistingDiagnostics(_ expected: String) async throws {
        let diagnostic: String
        switch expected {
        case "offline": diagnostic = "fatal: Could not resolve host: github.com"
        case "needs_github": diagnostic = "fatal: Authentication failed"
        case "not_found": diagnostic = "remote: Repository not found."
        default: diagnostic = "fatal: unexpected clone failure"
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent("git")
        try Data("#!/bin/sh\nprintf '%s\\n' \(CloudMachineBootstrap.shellQuoted(diagnostic + " fixture-secret")) >&2\nexit 128\n".utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
        let repo = CloudMachineRepo(owner: "octo", name: "paint")
        let step = root.appendingPathComponent("repo")
        try Data(repo.step.utf8).write(to: step)
        let ran = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [step.path],
            environment: ["HOME": root.path, "PATH": root.path + ":/usr/bin:/bin"],
            timeout: .seconds(10), clock: ContinuousClock())
        #expect(ran.status != 0)
        let record = try Data(contentsOf: root.appendingPathComponent("repo-status.json"))
        let object = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
        #expect(object["status"] as? String == expected)
        #expect(!String(decoding: record + ran.stdout + ran.stderr, as: UTF8.self).contains("fixture-secret"))
        let raw = "cmux-wait free 1000\n{\"state\":\"failed\",\"step\":\"repo\",\"exit_code\":1,\"repo\":\(String(decoding: record, as: UTF8.self))}"
        let read = CloudMachineBootstrap.read(.init(exitCode: 0, stdout: raw, stderr: ""), repo: repo)
        let failure: CloudMachineBootstrap.Run = switch expected {
        case "offline": .repoOffline(repo: "octo/paint")
        case "needs_github": .needsGitHub(repo: "octo/paint")
        case "not_found": .repoNotFound(repo: "octo/paint")
        default: .repoFailed(repo: "octo/paint")
        }
        #expect(read == .ended(failure))
    }

    @Test func retryUploadsOnlyTheRepositoryAndNoOpScript() async {
        let fake = RepoRetryMachine()
        let run = await CloudMachineRepo(owner: "octo", name: "paint").retry(on: fake.machine)
        #expect(run == .finished(repoPath: "/home/cmux/work/paint"))
        let scripts = await fake.scripts
        #expect(scripts == [CloudMachineBootstrap.noScript])
        #expect(await fake.waits == 1)
    }

    @Test(arguments: ["running", "failed"])
    func concurrentOrRefusedStartNeverWaitsOnAnotherBootstrap(_ outcome: String) async {
        let fake = RepoRetryMachine(outcome: outcome)
        let run = await CloudMachineRepo(owner: "octo", name: "paint").retry(on: fake.machine)
        #expect(run == (outcome == "running" ? .stillRunning : .repoFailed(repo: "octo/paint")))
        #expect(await fake.waits == 0)
    }

    @Test func unsafeDirectConstructionNeverReachesTheMachine() async {
        let fake = RepoRetryMachine()
        let run = await CloudMachineRepo(owner: "octo", name: "paint';exit 0").retry(on: fake.machine)
        #expect(run == .repoFailed(repo: ""))
        #expect(await fake.scripts.isEmpty)
        #expect(await fake.waits == 0)
    }
}

private actor RepoRetryMachine {
    private let outcome: String
    private(set) var scripts: [Data] = []
    private(set) var waits = 0

    init(outcome: String = "started") { self.outcome = outcome }

    nonisolated var machine: CloudMachineBootstrap.Machine {
        .init(write: { await self.write($0, data: $1, mode: $2) }, exec: { await self.exec($0) })
    }

    private func write(_ path: String, data: Data, mode: Int) {
        if path.hasSuffix("/script") { scripts.append(data) }
    }

    private func exec(_ command: String) -> CloudExecResult {
        if command.contains("cmux-wait") {
            waits += 1
            return .init(exitCode: 0, stdout: "cmux-wait free 1000\n{\"state\":\"done\",\"repo\":{\"status\":\"cloned\",\"dir\":\"/home/cmux/work/paint\"}}", stderr: "")
        }
        return .init(exitCode: outcome == "failed" ? 1 : 0, stdout: outcome, stderr: "")
    }
}
