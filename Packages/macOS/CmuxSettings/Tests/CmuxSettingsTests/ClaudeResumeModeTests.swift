import Foundation
import Testing
@testable import CmuxSettings

@Suite("ClaudeResumeMode")
struct ClaudeResumeModeTests {
    @Test func strictRawStringParse() {
        #expect(ClaudeResumeMode(rawString: "ask") == .ask)
        #expect(ClaudeResumeMode(rawString: "full") == .full)
        #expect(ClaudeResumeMode(rawString: "summary") == .summary)
        #expect(ClaudeResumeMode(rawString: "FULL") == .full)           // case-insensitive
        #expect(ClaudeResumeMode(rawString: "  summary ") == .summary)  // trimmed
        // Non-schema aliases must be rejected so invalid config is reported.
        #expect(ClaudeResumeMode(rawString: "manual") == nil)
        #expect(ClaudeResumeMode(rawString: "full-session") == nil)
        #expect(ClaudeResumeMode(rawString: "garbage") == nil)
        #expect(ClaudeResumeMode(rawString: "") == nil)
        #expect(ClaudeResumeMode(rawString: nil) == nil)
    }

    @Test func roundTripsThroughUserDefaultsAndJSON() {
        for mode in ClaudeResumeMode.allCases {
            #expect(ClaudeResumeMode.decodeFromUserDefaults(mode.encodeForUserDefaults()) == mode)
            #expect(ClaudeResumeMode.decodeFromJSON(mode.encodeForJSON()) == mode)
        }
        #expect(ClaudeResumeMode.decodeFromUserDefaults(42) == nil)
    }
}
