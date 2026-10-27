import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// p10-stability-191: the feed scrubber's rewritten patterns redact what the former ones did, and
/// stay linear on text built to make a backtracking matcher rescan.
@Suite struct FeedSecretScrubberBoundsTests {
    @Test func aValueAfterALongNameIsRedactedAndTheNameKept() {
        let name = "MY_SERVICE_" + String(repeating: "X", count: 200) + "_API_KEY"
        #expect(FeedSecretScrubber.scrub("\(name)=abcd1234 rest") == "\(name)=[redacted] rest")
        #expect(FeedSecretScrubber.scrub("export GITHUB_TOKEN='ghx0123456789'") == "export GITHUB_TOKEN='[redacted]'")
        #expect(FeedSecretScrubber.scrub("password: hunter22") == "password: [redacted]")
    }

    @Test func aJWTAfterAHyphenIsRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(FeedSecretScrubber.scrub("x-\(jwt) y") == "x-[redacted] y")
    }

    @Test func urlCredentialsAreRedacted() {
        #expect(FeedSecretScrubber.scrub("git clone https://u:p4ss@github.com/x") == "git clone [redacted]github.com/x")
        #expect(FeedSecretScrubber.scrub("a.b.c+ssh://u:p4ss@host") == "[redacted]host")
    }

    @Test func runsWithNothingToRedactStayAsWritten() {
        for piece in ["tokentoken", "eyJ-", "a.", "secret_"] {
            let text = String(repeating: piece, count: 2000)
            #expect(FeedSecretScrubber.scrub(text) == text)
        }
    }
}

/// The scrubber's time on 64 KiB built to make it rescan: under 50 ms, on every timed attempt (the
/// former patterns took seconds). Timing is not a CI check (Lawrence 2026-10-23): it runs with
/// `CMUX_REGEX_BUDGET_FUZZ=1`, which agents set on the fleet.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_REGEX_BUDGET_FUZZ"] == "1",
                "set CMUX_REGEX_BUDGET_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"))
struct FeedSecretScrubberBudgetTests {
    @Test func theScrubberIsLinear() throws {
        let bytes = 64 << 10
        let budget = FuzzBudget(perUnit: .milliseconds(50), unitBytes: bytes)
        for piece in ["tokentoken", "token= ", "eyJ-", "eyJabcdefgh.", "a.", "a", "Bearer ", "-----BEGIN A PRIVATE KEY-----"] {
            let text = FuzzText.truncated(String(repeating: piece, count: bytes / piece.utf8.count + 1), toBytes: bytes)
            try budget.check("FeedSecretScrubber.scrub of \(piece.debugDescription) repeated", bytes: text.utf8.count) { _ in
                _ = FeedSecretScrubber.scrub(text)
            }
        }
    }
}
