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

    @Test
    func parsesNULTerminatedPathContainingNewline() throws {
        let fixture = "worktree /repo/line\nbreak\0HEAD 1111111111111111111111111111111111111111\0branch refs/heads/main\0\0"

        let parsed = WorktreePorcelainParser().parse(
            fixture,
            host: WorktreeHostID(rawValue: "fixture-host"),
            fallbackRepoPath: "/unused"
        )

        let worktree = try #require(parsed.first)
        #expect(parsed.count == 1)
        #expect(worktree.identity.worktreePath == "/repo/line\nbreak")
        #expect(worktree.branch == "main")
    }

    @Test
    func ignoresUnknownNULTerminatedAttributesForForwardCompatibility() throws {
        let fixture = "worktree /repo\0HEAD 1111111111111111111111111111111111111111\0" +
            "branch refs/heads/main\0future-attribute some value\0\0"

        let parsed = WorktreePorcelainParser().parse(
            fixture,
            host: WorktreeHostID(rawValue: "fixture-host"),
            fallbackRepoPath: "/unused"
        )

        let worktree = try #require(parsed.first)
        #expect(parsed.count == 1)
        #expect(worktree.identity.worktreePath == "/repo")
        #expect(worktree.branch == "main")
    }

    @Test
    func omitsAmbiguousLineTerminatedRecord() {
        let fixture = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /repo/line
        break
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/topic

        """

        let parsed = WorktreePorcelainParser().parse(
            fixture,
            host: WorktreeHostID(rawValue: "fixture-host"),
            fallbackRepoPath: "/unused"
        )

        #expect(parsed.map(\.identity.worktreePath) == ["/repo"])
    }

    @Test
    func decodesCQuotedLineTerminatedPathEscapesAndUTF8OctalBytes() throws {
        let fixture = #"""
        worktree "/repo/\a\b\t\n\v\f\r\"\\Caf\303\251"
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        """#

        let parsed = WorktreePorcelainParser().parse(
            fixture,
            host: WorktreeHostID(rawValue: "fixture-host"),
            fallbackRepoPath: "/unused"
        )

        let worktree = try #require(parsed.first)
        #expect(parsed.count == 1)
        #expect(worktree.identity.worktreePath == "/repo/\u{7}\u{8}\t\n\u{B}\u{C}\r\"\\Café")
    }
}
