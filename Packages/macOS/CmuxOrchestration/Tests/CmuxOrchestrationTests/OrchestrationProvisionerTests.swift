import Foundation
import Testing
@testable import CmuxOrchestration

/// Recording process-runner fake with per-call behavior.
final class FakeProcessRunner: OrchestrationProcessRunner, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var currentDirectory: String?
        var environment: [String: String]?
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    /// Invoked for each run; returns the result and may mutate the fake FS.
    var handler: @Sendable (Call) -> OrchestrationProcessResult = { _ in
        OrchestrationProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    func run(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        environment: [String: String]?
    ) throws -> OrchestrationProcessResult {
        let call = Call(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment
        )
        lock.lock()
        calls.append(call)
        lock.unlock()
        return handler(call)
    }
}

@Suite struct OrchestrationProvisionerTests {
    private func workspacePlan(
        directory: String = "/root/ws/run-t1",
        provision: OrchestrationProvisionSpec
    ) -> OrchestrationWorkspacePlan {
        OrchestrationWorkspacePlan(
            title: "t1",
            directory: directory,
            branch: "fleet/run-t1",
            provision: provision,
            filesToWrite: [OrchestrationPlannedFile(relativePath: ".cmux/orchestration-prompt.md", contents: "PROMPT")],
            commandText: "claude 'PROMPT'",
            env: ["CMUX_ORCHESTRATION": "fleet"]
        )
    }

    @Test func worktreeProvisionRunsGitAndWritesFiles() throws {
        let fileSystem = InMemoryFileSystem()
        let runner = FakeProcessRunner()
        let directory = "/root/ws/run-t1"
        runner.handler = { call in
            // Simulate `git worktree add` creating the directory.
            if call.arguments.contains("worktree") {
                fileSystem.addDirectory(directory)
            }
            return OrchestrationProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let provisioner = OrchestrationProvisioner(fileSystem: fileSystem, processRunner: runner)

        try provisioner.provision(workspacePlan(
            directory: directory,
            provision: .gitWorktree(repoRoot: "/repos/proj", branch: "fleet/run-t1")
        ))

        #expect(runner.calls == [FakeProcessRunner.Call(
            executable: "git",
            arguments: ["-C", "/repos/proj", "worktree", "add", "-b", "fleet/run-t1", directory],
            currentDirectory: nil,
            environment: nil
        )])
        #expect(fileSystem.fileContents(directory + "/.cmux/orchestration-prompt.md") == "PROMPT")
    }

    @Test func cloneProvisionClonesThenBranches() throws {
        let fileSystem = InMemoryFileSystem()
        let runner = FakeProcessRunner()
        let directory = "/root/ws/run-t1"
        runner.handler = { call in
            if call.arguments.first == "clone" {
                fileSystem.addDirectory(directory)
            }
            return OrchestrationProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let provisioner = OrchestrationProvisioner(fileSystem: fileSystem, processRunner: runner)

        try provisioner.provision(workspacePlan(
            directory: directory,
            provision: .gitClone(repoRoot: "/repos/proj", branch: "fleet/run-t1")
        ))

        #expect(runner.calls.count == 2)
        #expect(runner.calls[0].arguments == ["clone", "--", "/repos/proj", directory])
        #expect(runner.calls[1].arguments == ["-C", directory, "checkout", "-b", "fleet/run-t1"])
    }

    @Test func gitFailureSurfacesStderr() {
        let fileSystem = InMemoryFileSystem()
        let runner = FakeProcessRunner()
        runner.handler = { _ in
            OrchestrationProcessResult(exitCode: 128, standardOutput: "", standardError: "fatal: not a git repository")
        }
        let provisioner = OrchestrationProvisioner(fileSystem: fileSystem, processRunner: runner)

        do {
            try provisioner.provision(workspacePlan(provision: .gitWorktree(repoRoot: "/repos/x", branch: "b")))
            Issue.record("expected provision to throw")
        } catch let error as OrchestrationProvisionError {
            #expect(error.message.contains("exited 128"))
            #expect(error.message.contains("not a git repository"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func refusesExistingDirectory() {
        let fileSystem = InMemoryFileSystem()
        fileSystem.addDirectory("/root/ws/run-t1")
        let provisioner = OrchestrationProvisioner(fileSystem: fileSystem, processRunner: FakeProcessRunner())

        #expect(throws: OrchestrationProvisionError.self) {
            try provisioner.provision(workspacePlan(provision: .gitWorktree(repoRoot: "/repos/x", branch: "b")))
        }
    }

    @Test func scriptProvisionPassesDirectoryAndEnv() throws {
        let fileSystem = InMemoryFileSystem()
        fileSystem.addFile("/tpl/scripts/provision-workspace", "#!/bin/sh", executable: true)
        let runner = FakeProcessRunner()
        let directory = "/root/ws/run-t1"
        runner.handler = { _ in
            fileSystem.addDirectory(directory)
            return OrchestrationProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let provisioner = OrchestrationProvisioner(fileSystem: fileSystem, processRunner: runner)

        try provisioner.provision(workspacePlan(
            directory: directory,
            provision: .script(scriptPath: "/tpl/scripts/provision-workspace")
        ))

        let call = try #require(runner.calls.first)
        #expect(call.executable == "/tpl/scripts/provision-workspace")
        #expect(call.arguments == [directory])
        #expect(call.currentDirectory == "/root/ws")
        #expect(call.environment?["CMUX_ORCHESTRATION"] == "fleet")
    }

    @Test func scriptMustExistAndProduceDirectory() {
        let fileSystem = InMemoryFileSystem()
        let provisioner = OrchestrationProvisioner(fileSystem: fileSystem, processRunner: FakeProcessRunner())

        // Missing script.
        #expect(throws: OrchestrationProvisionError.self) {
            try provisioner.provision(workspacePlan(provision: .script(scriptPath: "/tpl/none")))
        }

        // Script "succeeds" but never creates the directory.
        fileSystem.addFile("/tpl/scripts/provision-workspace", "#!/bin/sh", executable: true)
        #expect(throws: OrchestrationProvisionError.self) {
            try provisioner.provision(workspacePlan(provision: .script(scriptPath: "/tpl/scripts/provision-workspace")))
        }
    }
}

@Suite struct OrchestrationParameterResolutionTests {
    private func manifest() throws -> OrchestrationManifest {
        try OrchestrationManifest.parse(data: Data(minimalManifestJSON().utf8)).manifest
    }

    @Test func coercesKnownKeysByDeclaredType() throws {
        let result = try manifest().coerceParameterOverrides(
            ["repo_root": "/repos/x", "concurrency": "4"]
        )
        #expect(result == .success(["repo_root": .string("/repos/x"), "concurrency": .int(4)]))
    }

    @Test func rejectsUnknownKeysAndBadValues() throws {
        let unknown = try manifest().coerceParameterOverrides(["ghost": "1"])
        guard case .failure(let unknownProblem) = unknown else {
            Issue.record("expected failure")
            return
        }
        #expect(unknownProblem.key == "ghost")

        let badValue = try manifest().coerceParameterOverrides(["concurrency": "lots"])
        guard case .failure(let badProblem) = badValue else {
            Issue.record("expected failure")
            return
        }
        #expect(badProblem.key == "concurrency")
    }
}
