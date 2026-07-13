import Testing

@testable import CmuxGit

@Suite struct WorkspaceGitDiffAccumulatorTests {
    @Test func crossingCapTruncatesCurrentAndRemainingPathsInOrder() {
        var accumulator = WorkspaceGitDiffAccumulator(byteCap: 10)
        let continuedAfterFirst = accumulator.append(path: "first.swift", patch: "123456")
        let continuedAfterSecond = accumulator.append(path: "second.swift", patch: "12345")
        #expect(continuedAfterFirst)
        #expect(!continuedAfterSecond)
        accumulator.appendTruncated(contentsOf: ["third.swift", "fourth.swift"])

        let response = accumulator.response()
        #expect(response.patch == "123456")
        #expect(response.included == ["first.swift"])
        #expect(response.truncated == ["second.swift", "third.swift", "fourth.swift"])
        #expect(response.tooLarge.isEmpty)
    }

    @Test func individuallyOversizedPathIsReportedWithoutBlockingLaterPaths() {
        var accumulator = WorkspaceGitDiffAccumulator(byteCap: 10)
        let continuedAfterHuge = accumulator.append(path: "huge.swift", patch: "12345678901")
        let continuedAfterSmall = accumulator.append(path: "small.swift", patch: "1234")
        #expect(continuedAfterHuge)
        #expect(continuedAfterSmall)

        let response = accumulator.response()
        #expect(response.patch == "1234")
        #expect(response.included == ["small.swift"])
        #expect(response.truncated.isEmpty)
        #expect(response.tooLarge == [WorkspaceGitTooLargePath(path: "huge.swift", bytes: 11)])
    }

    @Test func emptyPatchDoesNotClaimPathAsIncluded() {
        var accumulator = WorkspaceGitDiffAccumulator(byteCap: 10)
        let continued = accumulator.append(path: "unchanged.swift", patch: "")
        #expect(continued)

        let response = accumulator.response()
        #expect(response.patch.isEmpty)
        #expect(response.included.isEmpty)
        #expect(response.truncated.isEmpty)
        #expect(response.tooLarge.isEmpty)
    }
}
