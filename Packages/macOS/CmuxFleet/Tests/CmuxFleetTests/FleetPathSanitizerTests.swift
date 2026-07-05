import CmuxFleet
import Testing

@Suite("FleetPathSanitizer")
struct FleetPathSanitizerTests {
    @Test func leavesAllowedCharactersIntact() {
        let sanitizer = FleetPathSanitizer()

        #expect(sanitizer.directoryName(for: "abc.DEF-123_ok") == "abc.DEF-123_ok")
    }

    @Test func replacesInvalidCharactersAndCollapsesReplacements() {
        let sanitizer = FleetPathSanitizer()

        #expect(sanitizer.directoryName(for: "github:owner/repo#123") == "github_owner_repo_123")
        #expect(sanitizer.directoryName(for: "a///b:::c") == "a_b_c")
    }

    @Test func trimsUnsafeEdges() {
        let sanitizer = FleetPathSanitizer()

        #expect(sanitizer.directoryName(for: "..._task---") == "task")
        #expect(sanitizer.directoryName(for: "///task///") == "task")
    }

    @Test func capsLengthThenTrimsAgain() {
        #expect(FleetPathSanitizer(maxLength: 4).directoryName(for: "abcdef-") == "abcd")
        #expect(FleetPathSanitizer(maxLength: 6).directoryName(for: "abc---def") == "abc")
    }

    @Test func neverReturnsEmpty() {
        #expect(FleetPathSanitizer().directoryName(for: "////") == "task")
        #expect(FleetPathSanitizer(maxLength: 100).directoryName(for: "") == "task")
        #expect(FleetPathSanitizer(maxLength: 0).directoryName(for: "abc") == "task")
        #expect(FleetPathSanitizer(maxLength: 0, fallback: "fallback").directoryName(for: "abc") == "task")
    }

    @Test func sanitizesFallbackThroughSamePipeline() {
        #expect(FleetPathSanitizer(fallback: "../x").directoryName(for: "///") == "x")
        #expect(FleetPathSanitizer(fallback: "a/b").directoryName(for: "") == "a_b")
        #expect(FleetPathSanitizer(fallback: "").directoryName(for: "") == "task")
        #expect(FleetPathSanitizer(maxLength: 2, fallback: "abc/def").directoryName(for: "") == "ab")
    }
}
