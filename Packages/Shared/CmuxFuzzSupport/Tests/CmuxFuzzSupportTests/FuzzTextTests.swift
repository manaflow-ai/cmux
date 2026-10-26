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

    @Test func anInputWithinTheLimitRunsOnceAndOneOverItFailsAfterEveryAttempt() throws {
        var runs = 0
        try FuzzBudget(perUnit: .seconds(60), unitBytes: 1).check("fast", bytes: 1) { _ in runs += 1 }
        #expect(runs == 1)

        var attempts: [Int] = []
        #expect(throws: FuzzError.self) {
            try FuzzBudget(perUnit: .zero, unitBytes: 1, attempts: 3).check("slow", bytes: 1) { attempt in
                attempts.append(attempt)
                // Work that always takes measurable time.
                _ = (0..<10_000).map { String($0) }.joined()
            }
        }
        #expect(attempts == [0, 1, 2])
    }
}
