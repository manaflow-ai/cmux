import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct DragOutWindowPolicyTests {
    let policy = DragOutWindowPolicy()
    let outside = CGPoint(x: 1200, y: 600)
    let windows = [CGRect(x: 0, y: 0, width: 1000, height: 800)]

    @Test func confirmedOutsideReleaseDetaches() {
        #expect(policy.shouldDetach(accepted: false, mouseReleased: true, cancelled: false,
                                    point: outside, windowFrames: windows))
    }

    @Test(arguments: [(true, true, false), (false, false, false), (false, true, true), (false, false, true)])
    func acceptedCancelledOrAmbiguousCompletionStaysPut(evidence: (Bool, Bool, Bool)) {
        #expect(!policy.shouldDetach(accepted: evidence.0, mouseReleased: evidence.1, cancelled: evidence.2,
                                     point: outside, windowFrames: windows))
    }

    @Test func anotherSameProcessWindowPreventsTearOff() {
        #expect(!policy.shouldDetach(accepted: false, mouseReleased: true, cancelled: false,
            point: outside, windowFrames: windows + [CGRect(x: 1100, y: 0, width: 500, height: 900)]))
    }

    @Test func invalidCoordinatesStayPut() {
        #expect(!policy.shouldDetach(accepted: false, mouseReleased: true, cancelled: false,
                                     point: CGPoint(x: CGFloat.nan, y: 0), windowFrames: []))
    }

    @Test func negativeDisplayOriginAndMenuBarAreRespected() {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1050)
        let frame = policy.frame(size: CGSize(width: 1100, height: 800),
                                  near: CGPoint(x: -1910, y: 770), visibleFrame: screen)
        #expect(screen.contains(frame))
        #expect(frame.minX == -1920)
        #expect(frame.maxY == screen.maxY)
    }

    @Test func oversizedWindowFitsSmallDisplay() {
        let screen = CGRect(x: 1200, y: 0, width: 800, height: 600)
        #expect(policy.frame(size: CGSize(width: 1400, height: 900), near: screen.origin,
                             visibleFrame: screen) == screen)
    }
}
