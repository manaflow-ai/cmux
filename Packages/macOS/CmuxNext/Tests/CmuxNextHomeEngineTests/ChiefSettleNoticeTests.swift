import Foundation
@testable import CmuxNextHomeEngine
import Testing

@Suite struct ChiefSettleNoticeTests {
    @Test func aSlowStartSaysTheMachineIsBusyWithItsWait() {
        let text = ChiefSettleNotice.text(json: Data(#"{"startingSecs":40}"#.utf8))
        #expect(text == HomeStrings.chiefStillStarting(seconds: 40))
        #expect(text?.contains("40") == true)
    }

    @Test func aSettleWaitStillCountsItsLines() {
        let text = ChiefSettleNotice.text(json: Data(#"{"built":2,"total":5}"#.utf8))
        #expect(text == HomeStrings.chiefOrganizing(built: 2, total: 5))
    }

    @Test func anythingElseIsNoNotice() {
        #expect(ChiefSettleNotice.text(json: Data(#"{"built":5,"total":5}"#.utf8)) == nil)
        #expect(ChiefSettleNotice.text(json: Data(#"{"startingSecs":-1}"#.utf8)) == nil)
        #expect(ChiefSettleNotice.text(json: Data("not json".utf8)) == nil)
    }
}
