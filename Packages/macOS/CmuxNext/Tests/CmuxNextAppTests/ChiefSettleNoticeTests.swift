import Foundation
import Testing
@testable import CmuxNextApp

/// While a turn waits for the compactor, the Chief conversation says how far
/// it is instead of nothing (onehist-import-v6, 2026-10-06: after a 177
/// message import the first send got no reply for minutes, with no word).
struct ChiefSettleNoticeTests {
    @Test func aWaitingTurnShowsBuiltOfTotal() {
        let json = Data(#"{"built": 8, "total": 308}"#.utf8)
        #expect(ChiefSettleNotice.text(json: json) == "Organizing Chief history: 8 of 308")
    }

    @Test func aSettledOrUnreadableFileShowsNothing() {
        #expect(ChiefSettleNotice.text(json: Data(#"{"built": 308, "total": 308}"#.utf8)) == nil)
        #expect(ChiefSettleNotice.text(json: Data("not json".utf8)) == nil)
        #expect(ChiefSettleNotice.text(json: Data(#"{"built": 1}"#.utf8)) == nil)
    }
}
