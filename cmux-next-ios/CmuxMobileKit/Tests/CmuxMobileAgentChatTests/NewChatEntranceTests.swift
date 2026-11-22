#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The new-chat entrance's poses: every look rests at identity (so the settled screen is the
/// screen as it was before the entrance), starts invisible, and the shipped look is `rise`.
@MainActor
@Suite struct NewChatEntranceTests {
    let parts: [NewChatEntrance.Part] = [.mark, .title, .detail, .composer]

    @Test func everyLookRestsAtIdentity() {
        for style in NewChatEntrance.Style.allCases {
            for part in parts {
                #expect(NewChatEntrance.pose(style, part, settled: true) == .rest)
            }
        }
    }

    @Test func everyLookStartsHiddenAndMoving() {
        for style in NewChatEntrance.Style.allCases {
            for part in parts {
                let start = NewChatEntrance.pose(style, part, settled: false)
                #expect(start.opacity == 0, "\(style) \(part) starts hidden")
                #expect(start != .rest, "\(style) \(part) moves")
            }
        }
    }

    /// The composer only rises and fades (no scale or blur over the text field and its glass).
    @Test func composerOnlyRises() {
        for style in NewChatEntrance.Style.allCases {
            let start = NewChatEntrance.pose(style, .composer, settled: false)
            #expect(start.scale == 1 && start.blur == 0 && start.y > 0)
        }
    }

    @Test func riseShips() {
        UserDefaults.standard.removeObject(forKey: "cmux-mobile-entrance")
        #expect(NewChatEntrance.Style.current == .rise)
    }
}
#endif
