@testable import CmuxMobileShell
import Testing

@Suite struct AgentFeedStopReasonCacheTests {
    @Test func unchangedSnapshotsReuseNormalizationAndDiscardRemovedReasons() {
        var normalized: [String] = []
        var cache = AgentFeedStopReasonCache { reason in
            normalized.append(reason)
            return reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let preview = "Completed\nthis…"
        let full = "Completed this task"
        for _ in 0..<100 {
            cache.retain(reasons: [preview, full])
            let matches = cache.matches(preview, full)
            #expect(matches)
        }
        #expect(normalized == [preview, full])

        cache.retain(reasons: [preview, "A different result"])
        let changedMatches = cache.matches(preview, "A different result")
        #expect(!changedMatches)
        #expect(normalized.count == 3)

        cache.retain(reasons: [])
        let restoredMatches = cache.matches(preview, full)
        #expect(restoredMatches)
        #expect(normalized.count == 5)
    }

    @Test(arguments: [
        ("Done\twith\nthis", "Done with this", true),
        ("Done\u{00a0}with\u{2003}this…", "Done with this task", true),
        ("Done", "Done with this task", false),
        ("Done with A", "Done with B", false),
        ("👨‍👩‍👧‍👦 Fixed…", "👨‍👩‍👧‍👦 Fixed the feed", true),
        ("  \n", "\t", false)
    ])
    func preservesTurnMatching(lhs: String, rhs: String, expected: Bool) {
        var cache = AgentFeedStopReasonCache()
        #expect(cache.matches(lhs, rhs) == expected)
        #expect(cache.matches(rhs, lhs) == expected)
    }
}
