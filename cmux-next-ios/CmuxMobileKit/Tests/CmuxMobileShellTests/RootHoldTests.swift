import Foundation
import Testing
@testable import CmuxMobileShell

/// #56696 F1 and F2: the root hold (the tab bar and New Task wait while a page leaves a tab's
/// stack) must end in every way UIKit can pop or not pop, and must not end while a page is
/// still on the stack and leaving.
///
/// Before this rule the enforcer released the hold only from a later layout or update of the
/// selected tab that found the stack at its root. So a hold stayed on when SwiftUI emptied the
/// path and then: no stack was found, the tab was not selected, or UIKit popped without a
/// transition and no layout reached the enforcer afterwards. And a push's completion released
/// it outright even when a Back had emptied the path during that push and UIKit had not
/// started the pop yet (the tab bar came back over the leaving page).
struct RootHoldTests {
    @Test func aRunningTransitionIsFollowedWhateverThePath() {
        for root in [true, false] {
            for depth in [nil, 1, 2, 3] as [Int?] {
                #expect(RootHold.step(transitioning: true, rootRequested: root, depth: depth, waited: 0) == .follow)
                #expect(RootHold.step(transitioning: true, rootRequested: root, depth: depth, waited: 60) == .follow)
            }
        }
    }

    @Test func anEmptiedPathWaitsForAPopUIKitHasNotStarted() {
        // F2: the push that a Back interrupted has completed, its page is still on the stack.
        #expect(RootHold.step(transitioning: false, rootRequested: true, depth: 2, waited: 0) == .wait)
        #expect(RootHold.step(transitioning: false, rootRequested: true, depth: 3, waited: RootHold.bound / 2) == .wait)
    }

    @Test func aPopUIKitNeverStartsIsReleasedAtTheBound() {
        // F1: UIKit does no pop. The hold fails open instead of hiding the tab bar for good.
        #expect(RootHold.step(transitioning: false, rootRequested: true, depth: 2, waited: RootHold.bound) == .release)
        #expect(RootHold.step(transitioning: false, rootRequested: true, depth: 2, waited: 3600) == .release)
    }

    @Test func aSettledRootReleases() {
        // A nonanimated pop, or a finished swipe: the stack is at its root.
        #expect(RootHold.step(transitioning: false, rootRequested: true, depth: 1, waited: 0) == .release)
        #expect(RootHold.step(transitioning: false, rootRequested: true, depth: 0, waited: 0) == .release)
    }

    @Test func noStackToWaitOnReleases() {
        // F1: the enforcer found no navigation stack; nothing would ever release the hold.
        #expect(RootHold.step(transitioning: false, rootRequested: true, depth: nil, waited: 0) == .release)
    }

    @Test func aPushedPageReleasesTheHold() {
        // A cancelled swipe (the path restored), or a path emptied and refilled in one update:
        // a page is on screen, so a root hold under it means nothing and must not linger.
        for depth in [nil, 1, 2] as [Int?] {
            #expect(RootHold.step(transitioning: false, rootRequested: false, depth: depth, waited: 0) == .release)
        }
    }

    @Test func aDeclinedTransitionWaitsOnTheBoundFromItsFirstDecline() {
        // UIKit declined to report the end (a nonanimated or ending change): bounded, unlike a
        // transition that reports its end, which is followed however long it runs.
        #expect(RootHold.step(transitioning: true, rootRequested: true, depth: 2, waited: 0, declined: 0) == .wait)
        #expect(RootHold.step(transitioning: true, rootRequested: true, depth: 2, waited: 0, declined: RootHold.bound / 2) == .wait)
        #expect(RootHold.step(transitioning: true, rootRequested: true, depth: 2, waited: 0, declined: RootHold.bound) == .release)
        #expect(RootHold.step(transitioning: true, rootRequested: true, depth: 2, waited: 60, declined: nil) == .follow)
    }

    @Test func theBoundIsShortAndTheRecheckFiner() {
        #expect(RootHold.bound <= 1.0)
        #expect(RootHold.recheck > 0 && RootHold.recheck < RootHold.bound / 10)
    }
}
