import CMUXAgentLaunch
import Testing

@Suite("Claude project session entry index")
struct ClaudeProjectSessionEntryIndexTests {
    private func index(_ folders: [(String, [String]?)]) -> ClaudeProjectSessionEntryIndex {
        var index = ClaudeProjectSessionEntryIndex()
        for (projectDir, entryNames) in folders {
            index.add(
                projectDir: projectDir,
                sessionIds: entryNames.flatMap(ClaudeProjectSessionEntryIndex.sessionIds(entryNames:))
            )
        }
        return index
    }

    @Test
    func entryNamesBecomeSessionIds() {
        let sessionIds = ClaudeProjectSessionEntryIndex.sessionIds(entryNames: [
            "aaaa.jsonl",
            "bbbb",
            "CCCC.JSONL",
            "memory",
        ])

        #expect(sessionIds == ["aaaa.jsonl", "aaaa", "bbbb", "cccc.jsonl", "cccc", "memory"])
    }

    @Test
    func sessionIsCheckedOnlyAgainstFoldersHoldingItsEntry() {
        let index = index([
            ("a", ["other.jsonl"]),
            ("b", ["wanted.jsonl", "other"]),
            ("c", []),
            ("d", ["wanted"]),
        ])

        #expect(index.projectDirs(sessionId: "wanted") == ["b", "d"])
        #expect(index.projectDirs(sessionId: "other") == ["a", "b"])
        #expect(index.projectDirs(sessionId: "never-written").isEmpty)
    }

    @Test
    func caseOfTheNameOrItsSuffixDoesNotHideAFolder() {
        let index = index([("a", ["ABCD.JSONL"]), ("b", ["abcd"])])

        #expect(index.projectDirs(sessionId: "abcd") == ["a", "b"])
        #expect(index.projectDirs(sessionId: "ABCD") == ["a", "b"])
    }

    @Test
    func sessionIdEndingInTheTranscriptSuffixKeepsItsFolder() {
        // The nested layout for this id is `foo.jsonl/messages/foo.jsonl.jsonl`.
        let index = index([("a", ["foo.jsonl"])])

        #expect(index.projectDirs(sessionId: "foo.jsonl") == ["a"])
        #expect(index.projectDirs(sessionId: "foo") == ["a"])
    }

    @Test
    func unlistedFoldersAreCheckedForEverySessionInListingOrder() {
        let index = index([("a", ["wanted"]), ("b", nil), ("c", ["wanted.jsonl"]), ("d", nil)])

        #expect(index.projectDirs(sessionId: "wanted") == ["a", "b", "c", "d"])
        #expect(index.projectDirs(sessionId: "never-written") == ["b", "d"])
    }

    @Test
    func namesAVolumeFoldsDifferentlyFallBackToCheckingTheFolder() {
        // A case-insensitive volume opens `ſ.jsonl` for the path `s.jsonl`.
        #expect(ClaudeProjectSessionEntryIndex.sessionIds(entryNames: ["ok.jsonl", "ſ.jsonl"]) == nil)
        let index = index([("a", ["ſ.jsonl"]), ("b", ["plain.jsonl"])])

        #expect(index.projectDirs(sessionId: "s") == ["a"])
        #expect(index.projectDirs(sessionId: "ς") == ["a", "b"])
    }
}
