import Foundation
import Testing
@testable import CmuxFeedPushCore

@Suite struct RemoteDismissTests {
    @Test func readsIdsAndBadge() {
        let dismiss = RemoteDismiss(userInfo: ["aps": ["content-available": 1], "cmux": ["dismiss": ["fi_1", "bad/id", "fi_2"], "badge": 3]])
        #expect(dismiss == RemoteDismiss(items: ["fi_1", "fi_2"], badge: 3))
    }

    @Test func aBadgeAloneIsEnoughAndNegativeClamps() {
        #expect(RemoteDismiss(userInfo: ["cmux": ["badge": -2]]) == RemoteDismiss(items: [], badge: 0))
    }

    @Test func otherPushesAreNotDismissals() {
        #expect(RemoteDismiss(userInfo: ["cmux": ["feed_item": "fi_1"]]) == nil)
        #expect(RemoteDismiss(userInfo: ["aps": ["alert": "x"]]) == nil)
    }
}
