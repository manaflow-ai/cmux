@testable import CmuxWorktrees
import Testing

@Suite
struct WorktreePorcelainParserTests {
    @Test
    func parsesLockedPrunableDetachedAndBareEntries() throws {
        let fixture = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main
        locked maintenance window

        worktree /repo/detached
        HEAD 2222222222222222222222222222222222222222
        detached
        prunable gitdir file points to non-existent location

        worktree /srv/archive.git
        bare

        """

        let parsed = WorktreePorcelainParser().parse(
            fixture,
            host: WorktreeHostID(rawValue: "fixture-host"),
            fallbackRepoPath: "/unused"
        )
        #expect(parsed.count == 3)

        let main = try #require(parsed.first)
        #expect(main.identity.repoPath == "/repo")
        #expect(main.branch == "main")
        #expect(main.isMainWorktree)
        #expect(main.isLocked)
        #expect(main.lockReason == "maintenance window")

        let detached = parsed[1]
        #expect(detached.isDetached)
        #expect(detached.branch == nil)
        #expect(detached.isPrunable)
        #expect(detached.prunableReason == "gitdir file points to non-existent location")
        #expect(detached.identity.repoPath == "/repo")

        let bare = parsed[2]
        #expect(bare.isBare)
        #expect(!bare.isMainWorktree)
        #expect(bare.headOID == nil)
    }
}
