import CmuxFuzzSupport
import Foundation
import Testing

@testable import CmuxSentryScrubbing

/// The scrubber's time budget on hostile text (p10-stability-191): every 64 KiB input, however it is
/// built to make a backtracking matcher rescan, scrubs in under 10 ms on every timed attempt. Chromium
/// bounds the same risk with RE2, a linear-time engine (third_party/re2), and with libFuzzer's slow-unit
/// timeout (testing/libfuzzer/README.md); Foundation's ICU matcher backtracks, so the bound is in the
/// patterns and in ``SentryScrubber/maxScrubbedScalars``, and this suite is the slow-unit check.
///
/// Timing is not a CI check (Lawrence 2026-10-23): it runs only with `CMUX_REGEX_BUDGET_FUZZ=1`, which
/// agents set on the fleet.
///
/// ```
/// CMUX_REGEX_BUDGET_FUZZ=1 swift test -c release --filter SentryScrubberBudgetFuzzTests
/// CMUX_REGEX_BUDGET_FUZZ=1 CMUX_FUZZ_SECONDS=300 swift test -c release --filter SentryScrubberBudgetFuzzTests
/// ```
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_REGEX_BUDGET_FUZZ"] == "1",
        "set CMUX_REGEX_BUDGET_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct SentryScrubberBudgetFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    static let inputBytes = 64 << 10
    static let budget = FuzzBudget(perUnit: .milliseconds(10), unitBytes: inputBytes)
    static let scrubber = SentryScrubber(homeDirectory: "/Users/dev")

    /// Pieces that, repeated, make one of the rules rescan: identifier runs around a marker, `eyJ` with no
    /// dot, local parts with no `@`, schemes with no `://`, PEM headers with no footer, long white space
    /// after a key, and the separators between them.
    static let pieces: [String] = [
        "a", "tokentoken", "tokenx", "eyJ-", "eyJa.-", "a.b", "a@", "x@b", "abc", "http://", "1.", "_",
        "-----BEGIN RSA PRIVATE KEY-----\n", "-----END X-----", " ", "\t", "Bearer ", "Authorization:", "sid",
        "4111 ", "=", ":", "\"", "'", "sk-", "/Users/", "/home/", "session_id", "Z9",
    ]

    /// `bytes` UTF-8 bytes of runs of pieces: each run long enough that the rule it targets sees it whole.
    static func hostileText(bytes: Int, _ rng: inout FuzzRNG) -> String {
        var text = ""
        while text.utf8.count < bytes {
            let piece = pieces[rng.below(pieces.count)]
            let most = max(1, bytes / piece.utf8.count)
            let long = rng.oneIn(3)
            text += String(repeating: piece, count: 1 + rng.below(long ? most : max(1, most / 64)))
        }
        return FuzzText.truncated(text, toBytes: bytes)
    }

    static func check(_ text: String, _ what: @autoclosure () -> String) throws {
        // The scrubber keeps no cache, so every attempt does all the work.
        try budget.check(what(), bytes: text.utf8.count) { _ in
            _ = scrubber.scrub(text)
        }
    }

    @Test(.timeLimit(.minutes(SentryScrubberBudgetFuzzTests.timeLimitMinutes)))
    func eachPieceRepeatedTo64KiBScrubsUnder10ms() throws {
        for piece in Self.pieces {
            let text = FuzzText.truncated(
                String(repeating: piece, count: Self.inputBytes / piece.utf8.count + 1), toBytes: Self.inputBytes
            )
            try Self.check(text, "SentryScrubber.scrub of \(piece.debugDescription) repeated")
        }
    }

    @Test(.timeLimit(.minutes(SentryScrubberBudgetFuzzTests.timeLimitMinutes)))
    func hostile64KiBTextScrubsUnder10ms() throws {
        try FuzzRun("SentryScrubber.budget", seed: 0x5C2B_0191, iterations: 48).forEach { rng in
            try Self.check(Self.hostileText(bytes: Self.inputBytes, &rng), "SentryScrubber.scrub of hostile text")
        }
    }
}
