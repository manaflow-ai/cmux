@testable import CmuxWorktrees
import Foundation
import Testing

@Suite
struct WorktreeCreateTests {
    @Test
    func createsNoTrackBranchRecordsConfigAndUsesDefaultLocation() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let remote = fixture.path("remote.git")
        _ = try await fixture.git(["init", "--bare", remote.path])
        _ = try await fixture.git(["remote", "add", "origin", remote.path])
        _ = try await fixture.git(["push", "-u", "origin", "main"])

        let created = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "Café .. feature",
            baseRef: "main",
            on: fixture.host
        )

        #expect(created.branch == "Café-feature")
        let normalizedCreatedPath = created.identity.worktreePath.precomposedStringWithCanonicalMapping
        #expect(normalizedCreatedPath.hasSuffix("/.cmux/worktrees/repo/Café-feature"))
        #expect(FileManager.default.fileExists(atPath: created.identity.worktreePath))
        #expect(created.warnings.isEmpty)

        let worktreeURL = URL(fileURLWithPath: created.identity.worktreePath)
        let tracking = await fixture.gitRaw(
            ["config", "--get", "branch.Café-feature.remote"],
            in: worktreeURL
        )
        #expect(tracking.exitStatus == 1)

        let pushSetup = try await fixture.git(["config", "--get", "push.autoSetupRemote"])
        #expect(pushSetup.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
        let base = try await fixture.git(["config", "--get", "branch.Café-feature.base"])
        #expect(base.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    @Test
    func initializesSubmodulesAndHonorsOptOut() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let submodule = fixture.path("submodule-source")
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        _ = try await fixture.git(["init", "-b", "main"], in: submodule)
        _ = try await fixture.git(["config", "user.name", "cmux tests"], in: submodule)
        _ = try await fixture.git(["config", "user.email", "cmux-tests@example.com"], in: submodule)
        try fixture.write("payload\n", to: "payload.txt", in: submodule)
        _ = try await fixture.git(["add", "payload.txt"], in: submodule)
        _ = try await fixture.git(["commit", "-m", "submodule"], in: submodule)

        _ = try await fixture.git([
            "-c", "protocol.file.allow=always", "submodule", "add",
            submodule.path, "modules/sample",
        ])
        try await fixture.commit("add submodule")

        let initializedPath = fixture.path("worktrees/initialized")
        let initialized = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "initialized",
            baseRef: "main",
            options: WorktreeCreateOptions(worktreePath: initializedPath.path),
            on: fixture.host
        )
        #expect(FileManager.default.fileExists(
            atPath: initialized.identity.worktreePath + "/modules/sample/payload.txt"
        ))

        let skippedPath = fixture.path("worktrees/skipped")
        let skipped = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "skipped",
            baseRef: "main",
            options: WorktreeCreateOptions(
                worktreePath: skippedPath.path,
                initializeSubmodules: false
            ),
            on: fixture.host
        )
        #expect(!FileManager.default.fileExists(
            atPath: skipped.identity.worktreePath + "/modules/sample/payload.txt"
        ))
    }

    @Test
    func rejectsTraversalInPathOverride() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }

        do {
            _ = try await WorktreeService().create(
                repoRoot: fixture.repository.path,
                name: "unsafe",
                baseRef: "HEAD",
                options: WorktreeCreateOptions(worktreePath: ".cmux/../elsewhere"),
                on: fixture.host
            )
            Issue.record("Expected path traversal to be rejected")
        } catch let error as WorktreeServiceError {
            #expect(error == .invalidPath(".cmux/../elsewhere"))
        }
    }

    @Test
    func returnsCanonicalPathWhenDestinationUsesSymlink() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let realParent = fixture.path("real-worktrees")
        let linkedParent = fixture.path("linked-worktrees")
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        let requestedPath = linkedParent.appendingPathComponent("topic")

        let created = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "topic",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: requestedPath.path),
            on: fixture.host
        )

        #expect(created.identity.worktreePath.hasSuffix("/real-worktrees/topic"))
        #expect(!created.identity.worktreePath.contains("/linked-worktrees/"))
    }

    @Test
    func createsFromInvokingLinkedWorktreeHead() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let service = WorktreeService()
        let callerPath = fixture.path("worktrees/caller")
        let caller = try await service.create(
            repoRoot: fixture.repository.path,
            name: "caller",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: callerPath.path),
            on: fixture.host
        )
        try fixture.write("caller\n", to: "caller.txt", in: callerPath)
        try await fixture.commit("caller commit", in: callerPath)
        let callerHead = try await fixture.git(["rev-parse", "HEAD"], in: callerPath)
        let mainHead = try await fixture.git(["rev-parse", "HEAD"])

        let child = try await service.create(
            repoRoot: caller.identity.worktreePath,
            name: "child",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: fixture.path("worktrees/child").path),
            on: fixture.host
        )

        #expect(child.headOID == callerHead.stdout?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(child.headOID != mainHead.stdout?.trimmingCharacters(in: .whitespacesAndNewlines))
        let recordedBase = try await fixture.git(["config", "--get", "branch.child.base"])
        #expect(recordedBase.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "caller")
    }

    @Test
    func recordsDetachedHeadLineageAsStableOID() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let head = try await fixture.git(["rev-parse", "HEAD"])
        let expectedOID = try #require(head.stdout?.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try await fixture.git(["checkout", "--detach", expectedOID])

        _ = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "detached-child",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(
                worktreePath: fixture.path("worktrees/detached-child").path
            ),
            on: fixture.host
        )

        let recordedBase = try await fixture.git(["config", "--get", "branch.detached-child.base"])
        #expect(recordedBase.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedOID)
    }
}
