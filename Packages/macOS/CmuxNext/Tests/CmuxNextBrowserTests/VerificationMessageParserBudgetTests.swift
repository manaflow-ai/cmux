@testable import CmuxNextBrowser
import Foundation
import Testing

/// p10-stability-191: the verification parser's patterns are linear as written (each run they
/// could rescan is guarded by a lookbehind that fails inside it), so a 64 KiB email built to make
/// a backtracking matcher rescan parses in under 50 ms. Timing is not a CI check (Lawrence
/// 2026-10-23): it runs with `CMUX_REGEX_BUDGET_FUZZ=1`, which agents set on the fleet.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_REGEX_BUDGET_FUZZ"] == "1",
                "set CMUX_REGEX_BUDGET_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"))
struct VerificationMessageParserBudgetTests {
    @Test(arguments: ["A", "1", "A1", "code 123 456 ", "@a.b #1234 ", "zip code ", "https://a.b/", "1-2 "])
    func a64KiBEmailParsesUnder50ms(piece: String) {
        let body = "Your verification code\n" + String(repeating: piece, count: (64 << 10) / piece.utf8.count)
        let email = VerificationEmail(id: "m1", senderAddress: "noreply@github.com", senderAuthenticated: true,
                                      subject: "code", body: body, links: [], receivedAt: Date(timeIntervalSince1970: 1_000))
        let took = ContinuousClock().measure { _ = VerificationMessageParser().parse(email) }
        #expect(took < .milliseconds(50), "\(piece.debugDescription) repeated took \(took)")
    }
}
