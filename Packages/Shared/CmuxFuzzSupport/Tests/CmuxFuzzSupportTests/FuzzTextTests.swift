@testable import CmuxFuzzSupport
import Foundation
import Testing

@Suite struct FuzzTextTests {
    @Test func aSeedGivesTheSameTextWithinItsBound() {
        let generator = FuzzText(maxBytes: 4096)
        for seed in UInt64(1)...40 {
            var a = FuzzRNG(seed: seed)
            var b = FuzzRNG(seed: seed)
            let text = generator.text(&a)
            #expect(text == generator.text(&b))
            #expect(text.utf8.count <= 4096)
            let edited = generator.edit(text, &a)
            #expect(edited.utf8.count <= 4096)
        }
    }

    @Test func aStreamGrowsToTheWholeText() {
        var rng = FuzzRNG(seed: 7)
        let text = "a\u{1F468}\u{200D}\u{1F469}\r\n```swift\nlet x = 1\n"
        let prefixes = FuzzText.stream(text, steps: 12, &rng)
        #expect(prefixes.last == text)
        for (shorter, longer) in zip(prefixes, prefixes.dropFirst()) {
            #expect(longer.unicodeScalars.starts(with: shorter.unicodeScalars))
            #expect(longer.unicodeScalars.count > shorter.unicodeScalars.count)
        }
        #expect(FuzzText.stream("", steps: 3, &rng) == [""])
    }

    @Test func sizedTextsAreNearTheirSizeAndAReplayThatRunsOutEnds() {
        for seed in UInt64(1)...12 {
            var rng = FuzzRNG(seed: seed)
            let text = FuzzText.sized(bytes: 1 << 16, &rng)
            #expect(text.utf8.count <= 1 << 16)
            #expect(text.utf8.count > (1 << 16) - 128)
        }
        var replay = FuzzRNG(replaying: Data([2, 9]))
        _ = FuzzText(maxBytes: 1 << 16).text(&replay)
        _ = FuzzText.sized(bytes: 1 << 12, &replay)
        #expect(replay.isExhausted)
    }

    @Test func truncationKeepsWholeScalars() {
        let text = "ab\u{1F600}cd"
        #expect(FuzzText.truncated(text, toBytes: 4) == "ab")
        #expect(FuzzText.truncated(text, toBytes: 6) == "ab\u{1F600}")
        #expect(FuzzText.truncated(text, toBytes: 100) == text)
    }
}

@Suite struct FuzzBudgetTests {
    @Test func theLimitScalesWithTheInputAndNeverGoesUnderOneUnit() {
        let budget = FuzzBudget(perUnit: .milliseconds(50), unitBytes: 1 << 16)
        #expect(FuzzBudget.milliseconds(budget.limit(bytes: 0)) == "50.0")
        #expect(FuzzBudget.milliseconds(budget.limit(bytes: 1 << 16)) == "50.0")
        #expect(FuzzBudget.milliseconds(budget.limit(bytes: 1 << 17)) == "100.0")
    }

    @Test func everyAttemptRunsAndTheSlowestDecides() throws {
        var runs: [Int] = []
        let timings = try FuzzBudget(perUnit: .seconds(60), unitBytes: 1, attempts: 3).check("fast", bytes: 1) { runs.append($0) }
        #expect(runs == [0, 1, 2])
        #expect(timings.sorted.count == 3)

        // Fast, then one attempt over the limit: the input fails (no best-of-N), naming the distribution.
        var attempts: [Int] = []
        do {
            try FuzzBudget(perUnit: .milliseconds(5), unitBytes: 1, attempts: 3).check("slow", bytes: 1) { attempt in
                attempts.append(attempt)
                if attempt == 1 { _ = (0..<200_000).map { String($0) }.joined() } // work well past 5 ms
            }
            Issue.record("an attempt over the limit passed")
        } catch let error as FuzzError {
            #expect(String(describing: error).contains("p50"))
            #expect(String(describing: error).contains("max"))
        }
        #expect(attempts == [0, 1, 2])
    }

    @Test func timingsGiveNearestRankQuantiles() {
        let t = FuzzBudget.Timings([.milliseconds(30), .milliseconds(10), .milliseconds(20)])
        #expect(t.p50 == .milliseconds(20))
        #expect(t.p95 == .milliseconds(30))
        #expect(t.slowest == .milliseconds(30))
        #expect(FuzzBudget.Timings([]).slowest == .zero)
    }
}
