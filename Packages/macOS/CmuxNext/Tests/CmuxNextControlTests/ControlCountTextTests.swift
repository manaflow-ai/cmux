@testable import CmuxNextControl
import Foundation
import Testing

/// Socket errors that hold a number: the queue and batch counts follow labels, and the byte limit is written by Foundation
/// with its byte unit (Polish needs a different noun for 4,194,304 than for 5).
@MainActor
struct ControlCountTextTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    @Test func busyCountsFollowLabels() {
        #expect(ControlStrings.busy(pending: 300, limit: 256, preferredLocalizations: ["en"], locale: Self.latin)
            == "cmux is busy (queued requests: 300, limit 256); retry later")
    }

    @Test func batchCountsFollowLabels() {
        #expect(ControlStrings.batchTooLarge(limit: 1, got: 300, preferredLocalizations: ["en"], locale: Self.latin)
            == "action.batch: too many ops for one transaction (limit 1, got 300); send several batches, or atomic: false to apply it as consecutive transactions")
        let polish = ControlStrings.batchTooLarge(limit: 1, got: 5, preferredLocalizations: ["pl"], locale: Self.latin)
        #expect(polish.range(of: "(limit 1, otrzymano 5)", options: .literal) != nil)
    }

    @Test func theLineLimitIsFoundationsByteCount() {
        #expect(ControlStrings.requestTooLarge(limit: 4 << 20, preferredLocalizations: ["en"], locale: Self.latin)
            == "Request line exceeds 4,194,304 bytes")
        let polish = ControlStrings.requestTooLarge(limit: 4 << 20, preferredLocalizations: ["pl"], locale: Self.latin)
        let bytes = Int64(4 << 20).formatted(.byteCount(style: .file, allowedUnits: .bytes, spellsOutZero: false)
            .locale(Locale(identifier: "pl_US@numbers=latn")))
        #expect(polish == "Wiersz żądania przekracza \(bytes)")
    }
}
