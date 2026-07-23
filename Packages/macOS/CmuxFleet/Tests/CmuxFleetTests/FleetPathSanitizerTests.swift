import CmuxFleet
import Testing

@Suite("FleetPathSanitizer")
struct FleetPathSanitizerTests {
    @Test func leavesAllowedCharactersIntact() {
        let sanitizer = FleetPathSanitizer()

        #expect(hasHashSuffix(sanitizer.directoryName(for: "abc.DEF-123_ok"), base: "abc.DEF-123_ok"))
    }

    @Test func replacesInvalidCharactersAndCollapsesReplacements() {
        let sanitizer = FleetPathSanitizer()

        #expect(hasHashSuffix(sanitizer.directoryName(for: "github:owner/repo#123"), base: "github_owner_repo_123"))
        #expect(hasHashSuffix(sanitizer.directoryName(for: "a///b:::c"), base: "a_b_c"))
    }

    @Test func trimsUnsafeEdges() {
        let sanitizer = FleetPathSanitizer()

        #expect(hasHashSuffix(sanitizer.directoryName(for: "..._task---"), base: "task"))
        #expect(hasHashSuffix(sanitizer.directoryName(for: "///task///"), base: "task"))
    }

    @Test func capsLengthThenTrimsAgain() {
        let capped = FleetPathSanitizer(maxLength: 20).directoryName(for: "abcdefghijklmnop")
        #expect(hasHashSuffix(capped, base: "abcdefghijk"))
        #expect(capped.count == 20)

        let trimmed = FleetPathSanitizer(maxLength: 15).directoryName(for: "abc---def")
        #expect(hasHashSuffix(trimmed, base: "abc"))
    }

    @Test func neverReturnsEmpty() {
        #expect(hasHashSuffix(FleetPathSanitizer().directoryName(for: "////"), base: "task"))
        #expect(hasHashSuffix(FleetPathSanitizer(maxLength: 100).directoryName(for: ""), base: "task"))
        #expect(hasHashSuffix(FleetPathSanitizer(maxLength: 0).directoryName(for: "abc"), base: "abc"))
        #expect(hasHashSuffix(FleetPathSanitizer(maxLength: 0, fallback: "fallback").directoryName(for: "///"), base: "fall"))
    }

    @Test func sanitizesFallbackThroughSamePipeline() {
        #expect(hasHashSuffix(FleetPathSanitizer(fallback: "../x").directoryName(for: "///"), base: "x"))
        #expect(hasHashSuffix(FleetPathSanitizer(fallback: "a/b").directoryName(for: ""), base: "a_b"))
        #expect(hasHashSuffix(FleetPathSanitizer(fallback: "").directoryName(for: ""), base: "task"))
        #expect(hasHashSuffix(FleetPathSanitizer(maxLength: 2, fallback: "abc/def").directoryName(for: ""), base: "abc"))
    }

    @Test func collidingSanitizedKeysStillDifferByHash() {
        let sanitizer = FleetPathSanitizer()
        let slash = sanitizer.directoryName(for: "a/b")
        let colon = sanitizer.directoryName(for: "a:b")

        #expect(hasHashSuffix(slash, base: "a_b"))
        #expect(hasHashSuffix(colon, base: "a_b"))
        #expect(slash != colon)
    }

    @Test func longKeysDifferingAfterTruncationStillDifferByHash() {
        let sanitizer = FleetPathSanitizer(maxLength: 30)
        let longPrefix = String(repeating: "a", count: 80)
        let truncatedPrefix = String(repeating: "a", count: 21)
        let first = sanitizer.directoryName(for: "\(longPrefix)1")
        let second = sanitizer.directoryName(for: "\(longPrefix)2")

        #expect(first.hasPrefix("\(truncatedPrefix)-"))
        #expect(second.hasPrefix("\(truncatedPrefix)-"))
        #expect(first.count == 30)
        #expect(second.count == 30)
        #expect(first != second)
    }

    @Test func hashSuffixIsDeterministicAcrossCalls() {
        let sanitizer = FleetPathSanitizer()

        #expect(sanitizer.directoryName(for: "github:owner/repo#123") == sanitizer.directoryName(for: "github:owner/repo#123"))
    }

    private func hasHashSuffix(_ value: String, base: String) -> Bool {
        guard value.hasPrefix("\(base)-") else {
            return false
        }
        let suffix = value.dropFirst(base.count + 1)
        return suffix.count == 8 && suffix.allSatisfy(isLowercaseHex)
    }

    private func isLowercaseHex(_ character: Character) -> Bool {
        switch character {
        case "0"..."9", "a"..."f":
            true
        default:
            false
        }
    }
}
