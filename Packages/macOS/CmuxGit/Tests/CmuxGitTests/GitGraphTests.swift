import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitGraphTests {
    @Test func parsesDecoratedCommitsAndNormalizesReferences() throws {
        let date = "2026-08-21T10:30:00+05:30"
        let output = Data(
            "abc\0parent\0HEAD -> refs/heads/feature, refs/remotes/origin/feature, tag: refs/tags/v1\0Ada\0\(date)\0Add graph\0".utf8
        )

        let commits = GitGraphSnapshotParser().commits(from: output)

        let commit = try #require(commits.first)
        #expect(commit.oid == "abc")
        #expect(commit.parentOIDs == ["parent"])
        #expect(commit.subject == "Add graph")
        #expect(commit.references == [
            GitGraphReference(name: "feature", kind: .branch),
            GitGraphReference(name: "origin/feature", kind: .remote),
            GitGraphReference(name: "v1", kind: .tag),
        ])
    }

    @Test func laysOutMergeParentsAsDistinctColoredLanes() throws {
        let now = Date(timeIntervalSince1970: 1)
        let commits = [
            GitGraphCommit(oid: "merge", parentOIDs: ["main", "feature"], references: [], author: "Ada", authoredAt: now, subject: "Merge"),
            GitGraphCommit(oid: "feature", parentOIDs: ["base"], references: [], author: "Ada", authoredAt: now, subject: "Feature"),
            GitGraphCommit(oid: "main", parentOIDs: ["base"], references: [], author: "Ada", authoredAt: now, subject: "Main"),
            GitGraphCommit(oid: "base", parentOIDs: [], references: [], author: "Ada", authoredAt: now, subject: "Base"),
        ]

        let rows = GitGraphLayout().rows(for: commits)

        #expect(rows[0].nodeLane == 0)
        #expect(rows[0].outgoingLanes.map(\.oid) == ["main", "feature"])
        #expect(rows[1].nodeLane == 1)
        #expect(rows[2].nodeLane == 0)
        #expect(rows[3].incomingLanes.count == 1)
        #expect(rows[3].outgoingLanes.isEmpty)
    }

    @Test func serviceLoadsBoundedSnapshotFromInjectedRunner() async throws {
        let root = "/tmp/repo"
        let logArguments = [
            "log", "--all", "--date-order", "--decorate=full", "--no-color", "--no-show-signature",
            "--max-count=501", "--format=%H%x00%P%x00%D%x00%an%x00%aI%x00%s%x00",
        ]
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("feature\n"),
            ["rev-parse", "--verify", "HEAD^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["status", "--porcelain=v1", "-z", "--ignore-submodules=dirty", "--no-renames"]: FakeWorkspaceChangesGitRunner.result("M"),
            logArguments: FakeWorkspaceChangesGitRunner.result("abc\0\0HEAD -> refs/heads/feature\0Ada\02026-08-21T10:30:00+05:30\0Initial\0"),
        ])

        let snapshot = try await GitGraphService(runner: runner).snapshot(forDirectory: root)

        #expect(snapshot.repositoryRoot == root)
        #expect(snapshot.branch == "feature")
        #expect(snapshot.headOID == "abc")
        #expect(snapshot.isDirty)
        #expect(snapshot.rows.count == 1)
    }

    @Test(arguments: [
        (GitGraphService.maximumCommitCount, GitGraphTruncation.none),
        (GitGraphService.maximumCommitCount + 1, GitGraphTruncation.commitLimit),
    ])
    func serviceUsesASentinelCommitToDetectTruncation(
        returnedCommitCount: Int,
        expectedTruncation: GitGraphTruncation
    ) async throws {
        let root = "/tmp/repo"
        let logArguments = [
            "log", "--all", "--date-order", "--decorate=full", "--no-color", "--no-show-signature",
            "--max-count=501", "--format=%H%x00%P%x00%D%x00%an%x00%aI%x00%s%x00",
        ]
        let records = (0..<returnedCommitCount).map { index in
            "commit-\(index)\0\0\0Ada\02026-08-21T10:30:00+05:30\0Commit \(index)\0"
        }.joined()
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("main\n"),
            ["rev-parse", "--verify", "HEAD^{commit}"]: FakeWorkspaceChangesGitRunner.result("commit-0\n"),
            ["status", "--porcelain=v1", "-z", "--ignore-submodules=dirty", "--no-renames"]: FakeWorkspaceChangesGitRunner.result(""),
            logArguments: FakeWorkspaceChangesGitRunner.result(records),
        ])

        let snapshot = try await GitGraphService(runner: runner).snapshot(forDirectory: root)

        #expect(snapshot.rows.count == min(returnedCommitCount, GitGraphService.maximumCommitCount))
        #expect(snapshot.truncation == expectedTruncation)
    }

    @Test func serviceDistinguishesOutputLimitFromCommitLimit() async throws {
        let root = "/tmp/repo"
        let logArguments = [
            "log", "--all", "--date-order", "--decorate=full", "--no-color", "--no-show-signature",
            "--max-count=501", "--format=%H%x00%P%x00%D%x00%an%x00%aI%x00%s%x00",
        ]
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("main\n"),
            ["rev-parse", "--verify", "HEAD^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["status", "--porcelain=v1", "-z", "--ignore-submodules=dirty", "--no-renames"]: FakeWorkspaceChangesGitRunner.result(),
            logArguments: FakeWorkspaceChangesGitRunner.result(
                "abc\0\0\0Ada\02026-08-21T10:30:00+05:30\0Initial\0",
                standardOutputWasTruncated: true
            ),
        ])

        let snapshot = try await GitGraphService(runner: runner).snapshot(forDirectory: root)

        #expect(snapshot.rows.count == 1)
        #expect(snapshot.truncation == .outputLimit)
    }
}
