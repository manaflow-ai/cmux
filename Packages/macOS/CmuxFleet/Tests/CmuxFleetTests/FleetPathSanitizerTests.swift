import CmuxFleet
import Testing

@Suite("FleetPathSanitizer")
struct FleetPathSanitizerTests {
    @Test func leavesAllowedCharactersIntact() {
        #expect(FleetPathSanitizer.directoryName(for: "abc.DEF-123_ok") == "abc.DEF-123_ok")
    }

    @Test func replacesInvalidCharactersAndCollapsesReplacements() {
        #expect(FleetPathSanitizer.directoryName(for: "github:owner/repo#123") == "github_owner_repo_123")
        #expect(FleetPathSanitizer.directoryName(for: "a///b:::c") == "a_b_c")
    }

    @Test func trimsUnsafeEdges() {
        #expect(FleetPathSanitizer.directoryName(for: "..._task---") == "task")
        #expect(FleetPathSanitizer.directoryName(for: "///task///") == "task")
    }

    @Test func capsLengthThenTrimsAgain() {
        #expect(FleetPathSanitizer.directoryName(for: "abcdef-", maxLength: 4) == "abcd")
        #expect(FleetPathSanitizer.directoryName(for: "abc---def", maxLength: 6) == "abc")
    }

    @Test func neverReturnsEmpty() {
        #expect(FleetPathSanitizer.directoryName(for: "////") == "task")
        #expect(FleetPathSanitizer.directoryName(for: "", maxLength: 100) == "task")
        #expect(FleetPathSanitizer.directoryName(for: "abc", maxLength: 0) == "task")
    }
}
