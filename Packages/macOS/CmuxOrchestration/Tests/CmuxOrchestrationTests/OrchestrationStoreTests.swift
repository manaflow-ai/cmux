import Foundation
import Testing
@testable import CmuxOrchestration

@Suite struct OrchestrationStoreTests {
    private struct Fixture {
        let fileSystem = InMemoryFileSystem()
        let git: FakeGitClient
        let store: OrchestrationStore
        let now: Date

        init(now: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
            self.now = now
            self.git = FakeGitClient(fileSystem: fileSystem)
            self.store = OrchestrationStore(
                rootDirectory: "/home/.cmuxterm/orchestrations",
                fileSystem: fileSystem,
                gitClient: git,
                now: { now }
            )
        }
    }

    private func templateFiles(name: String = "demo-fleet") -> [(path: String, contents: String)] {
        [
            ("orchestration.json", minimalManifestJSON(name: name)),
            ("prompts/task.md", "Do this: {{task}}"),
        ]
    }

    @Test func installsFromLocalPathAndAppliesDefaults() throws {
        let fixture = Fixture()
        addMinimalTemplate(to: fixture.fileSystem, at: "/src/demo")

        let outcome = try fixture.store.install(source: .localPath("/src/demo"))

        #expect(outcome.installed.manifest.name == "demo-fleet")
        #expect(outcome.installed.record.resolvedParameters["concurrency"] == .int(2))
        #expect(outcome.installed.record.resolvedParameters["repo_root"] == nil)
        #expect(outcome.unansweredParameters.map(\.key) == ["repo_root"])
        #expect(outcome.installed.record.trustConfirmedAt == nil)
        #expect(fixture.fileSystem.fileExists(
            atPath: "/home/.cmuxterm/orchestrations/demo-fleet/template/orchestration.json"
        ))
        #expect(fixture.fileSystem.fileExists(
            atPath: "/home/.cmuxterm/orchestrations/demo-fleet/install.json"
        ))
    }

    @Test func installFromGitRecordsCommit() throws {
        let fixture = Fixture()
        fixture.git.filesByURL["https://example.com/fleet.git"] = templateFiles()

        let outcome = try fixture.store.install(
            source: .git(url: "https://example.com/fleet.git", reference: "main", commit: nil)
        )

        guard case .git(let url, let reference, let commit) = outcome.installed.record.source else {
            Issue.record("expected git source")
            return
        }
        #expect(url == "https://example.com/fleet.git")
        #expect(reference == "main")
        #expect(commit == "abc1234")
        #expect(fixture.git.cloneCalls.count == 1)
    }

    @Test func installRejectsInvalidTemplates() {
        let fixture = Fixture()
        fixture.fileSystem.addDirectory("/src/bad")
        fixture.fileSystem.addFile("/src/bad/orchestration.json", "{ broken")

        #expect(throws: OrchestrationStoreError.self) {
            try fixture.store.install(source: .localPath("/src/bad"))
        }
        // Nothing installed, no staging left behind.
        #expect((try? fixture.store.list())?.isEmpty == true)
    }

    @Test func installRefusesDuplicateWithoutForce() throws {
        let fixture = Fixture()
        addMinimalTemplate(to: fixture.fileSystem, at: "/src/demo")
        _ = try fixture.store.install(source: .localPath("/src/demo"))

        #expect(throws: OrchestrationStoreError.alreadyInstalled("demo-fleet")) {
            try fixture.store.install(source: .localPath("/src/demo"))
        }
        _ = try fixture.store.install(source: .localPath("/src/demo"), force: true)
    }

    @Test func listSkipsPartialDirectoriesAndSorts() throws {
        let fixture = Fixture()
        addMinimalTemplate(to: fixture.fileSystem, at: "/src/b", name: "b-fleet")
        addMinimalTemplate(to: fixture.fileSystem, at: "/src/a", name: "a-fleet")
        _ = try fixture.store.install(source: .localPath("/src/b"))
        _ = try fixture.store.install(source: .localPath("/src/a"))
        fixture.fileSystem.addDirectory("/home/.cmuxterm/orchestrations/stray-dir")

        let names = try fixture.store.list().map(\.manifest.name)
        #expect(names == ["a-fleet", "b-fleet"])
    }

    @Test func removeDeletesInstallAndUnknownNameThrows() throws {
        let fixture = Fixture()
        addMinimalTemplate(to: fixture.fileSystem, at: "/src/demo")
        _ = try fixture.store.install(source: .localPath("/src/demo"))

        try fixture.store.remove(name: "demo-fleet")
        #expect((try fixture.store.list()).isEmpty)
        #expect(throws: OrchestrationStoreError.notInstalled("ghost")) {
            try fixture.store.remove(name: "ghost")
        }
    }

    @Test func parametersPersistAndTrustConfirms() throws {
        let fixture = Fixture()
        addMinimalTemplate(to: fixture.fileSystem, at: "/src/demo")
        _ = try fixture.store.install(source: .localPath("/src/demo"))

        _ = try fixture.store.setResolvedParameters(
            name: "demo-fleet",
            values: ["repo_root": .string("/repos/x")]
        )
        let record = try fixture.store.confirmTrust(name: "demo-fleet")
        #expect(record.resolvedParameters["repo_root"] == .string("/repos/x"))
        #expect(record.trustConfirmedAt == fixture.now)

        let reloaded = try fixture.store.installed(named: "demo-fleet")
        #expect(reloaded.record.trustConfirmedAt != nil)
    }

    @Test func updateKeepsParametersButResetsTrustAndDropsStaleKeys() throws {
        let fixture = Fixture()
        fixture.git.filesByURL["https://example.com/fleet.git"] = templateFiles()
        _ = try fixture.store.install(
            source: .git(url: "https://example.com/fleet.git", reference: nil, commit: nil)
        )
        _ = try fixture.store.setResolvedParameters(
            name: "demo-fleet",
            values: ["repo_root": .string("/repos/x")]
        )
        _ = try fixture.store.confirmTrust(name: "demo-fleet")

        // New template version drops the concurrency parameter and bumps version.
        let updatedManifest = """
        {
          "schemaVersion": 1,
          "name": "demo-fleet",
          "version": "1.1.0",
          "description": "Demo fleet",
          "parameters": [
            { "key": "repo_root", "prompt": "Repo path", "type": "path" }
          ],
          "substrate": { "kind": "worktree" },
          "agents": [
            { "id": "claude", "registryAgent": "claude", "command": "claude {{prompt}}" }
          ],
          "prompt": "prompts/task.md"
        }
        """
        fixture.git.filesByURL["https://example.com/fleet.git"] = [
            ("orchestration.json", updatedManifest),
            ("prompts/task.md", "Do this: {{task}}"),
        ]
        fixture.git.commit = "def5678"

        let outcome = try fixture.store.update(name: "demo-fleet")

        #expect(outcome.installed.record.templateVersion == "1.1.0")
        #expect(outcome.installed.record.trustConfirmedAt == nil)
        #expect(outcome.installed.record.resolvedParameters["repo_root"] == .string("/repos/x"))
        #expect(outcome.installed.record.resolvedParameters["concurrency"] == nil)
        guard case .git(_, _, let commit) = outcome.installed.record.source else {
            Issue.record("expected git source")
            return
        }
        #expect(commit == "def5678")
    }

    @Test func updateRejectsRenamedTemplates() throws {
        let fixture = Fixture()
        fixture.git.filesByURL["https://example.com/fleet.git"] = templateFiles()
        _ = try fixture.store.install(
            source: .git(url: "https://example.com/fleet.git", reference: nil, commit: nil)
        )
        fixture.git.filesByURL["https://example.com/fleet.git"] = templateFiles(name: "renamed-fleet")

        #expect(throws: OrchestrationStoreError.self) {
            try fixture.store.update(name: "demo-fleet")
        }
        // Original stays intact.
        #expect(try fixture.store.installed(named: "demo-fleet").manifest.name == "demo-fleet")
    }

    @Test func corruptInstallRecordSurfacesClearly() throws {
        let fixture = Fixture()
        addMinimalTemplate(to: fixture.fileSystem, at: "/src/demo")
        _ = try fixture.store.install(source: .localPath("/src/demo"))
        fixture.fileSystem.addFile("/home/.cmuxterm/orchestrations/demo-fleet/install.json", "gone wrong")

        #expect(throws: OrchestrationStoreError.self) {
            try fixture.store.installed(named: "demo-fleet")
        }
    }

    @Test func detectsGitVersusLocalSources() {
        #expect(OrchestrationInstallSource.detect(from: "https://github.com/a/b") == .git(url: "https://github.com/a/b", reference: nil, commit: nil))
        #expect(OrchestrationInstallSource.detect(from: "git@github.com:a/b.git") == .git(url: "git@github.com:a/b.git", reference: nil, commit: nil))
        #expect(OrchestrationInstallSource.detect(from: "/some/dir") == .localPath("/some/dir"))
        #expect(OrchestrationInstallSource.detect(from: "./relative") == .localPath("./relative"))
        #expect(OrchestrationInstallSource.detect(from: "~/templates/x") == .localPath("~/templates/x"))
    }
}
