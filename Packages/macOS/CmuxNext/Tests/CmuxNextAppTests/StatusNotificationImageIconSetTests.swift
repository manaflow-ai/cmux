import AppKit
import CmuxNextBridge
import CmuxNextDesign
import Testing
@testable import CmuxNextApp

/// cx-kxa2: an OSC 7501 notification's badge image draws the chosen status
/// icon set's mark for the reason, with the blocked kind.
@MainActor @Suite struct StatusNotificationImageIconSetTests {
    @Test func theBadgeFollowsTheSetAndTheKind() throws {
        let current = try #require(StatusNotificationImage.png(.question, set: .current))
        let badges = try #require(StatusNotificationImage.png(.question, set: .badges))
        #expect(current != badges, "the chosen set draws the badge")
        let auth = try #require(StatusNotificationImage.png(.auth, set: .badges))
        #expect(auth != badges, "a candidate set marks question and auth apart")
        #expect(StatusNotificationImage.png(.permission, set: .current) == StatusNotificationImage.png(.question, set: .current),
                "the default set keeps one mark for every blocked kind")
        for reason in ProgramStatusNotification.Reason.allCases {
            for set in StatusIconSet.allCases {
                #expect(StatusNotificationImage.png(reason, set: set) != nil, "\(reason) \(set)")
            }
        }
    }
}
