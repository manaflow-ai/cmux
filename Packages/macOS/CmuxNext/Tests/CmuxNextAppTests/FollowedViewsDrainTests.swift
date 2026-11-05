import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7, the end of a `FollowedViews` hold, second part. After the held frame notices go,
/// `endHold()` runs the held geometry posts, and each post runs the fork tracker's update and every other observer
/// inside it. Review of f5df3c37f6b (Codex): a hold that such an observer started then (a nested window step, or the
/// DEBUG hold across the commit, which ends at a later frame tick) took the posts made under it, and the release still
/// going then ran its own older post of the same page, which posted that page in the middle of the new hold and left
/// the new hold's post with nothing to send. A release now ends before any hold can begin, until its last post went:
/// a hold asked for then does not start, and the changes made then post at once.
///
/// The rig is `LiveResizeTrackerAfterLayoutTests`': two pages in one window and a tracker per page that observes as
/// the fork's does.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct FollowedViewsDrainTests {
    /// What the nested code saw.
    @MainActor final class Log {
        var nested = false
        var holdingInNested: Bool?
        var readAtNestedChange: Bool?
    }

    /// While the held posts go, the tracker's update of page A starts a hold (and leaves it on, as the DEBUG hold
    /// across the commit does) and changes page B's occlusion: the hold does not start, B's change reaches B's
    /// tracker at once, and when the release returns nothing holds.
    @Test func aHoldAskedForWhileTheHeldPostsGoDoesNotStart() throws {
        let rig = WindowLiveResizeFrameTickTests.Rig()
        defer { rig.close() }
        let pages = try LiveResizeTrackerAfterLayoutTests.stackedPages(in: rig)
        let (a, b) = (pages[0].host, pages[1].host)
        let trackers = [LiveResizeForkTracker(host: a), LiveResizeForkTracker(host: b)]
        defer { trackers.forEach { $0.stop() } }
        let views = FollowedViews.of(rig.window)
        let log = Log()
        let barA = CGRect(x: 0, y: 0, width: 50, height: 10)
        let barB = CGRect(x: 0, y: 0, width: 60, height: 12), newBarB = CGRect(x: 0, y: 0, width: 70, height: 14)
        // After A's tracker (it observes first): the nested step.
        // global-notice-allow: the fork's tracker hears these posts on the default center (only observed here)
        let observer = NotificationCenter.default.addObserver(forName: CEFHostView.geometryDidChange, object: a, queue: nil) { _ in
            MainActor.assumeIsolated { // main-proof: CEFHostView posts on the main thread
                guard !log.nested else { return }
                log.nested = true
                views.beginHold()
                log.holdingInNested = views.isHolding
                let reads = trackers[1].reads.count
                b.occlusionRects = [newBarB]
                log.readAtNestedChange = trackers[1].reads.count > reads
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        trackers.forEach { $0.reset() }
        views.beginHold()
        a.occlusionRects = [barA]
        b.occlusionRects = [barB]
        views.endHold()
        let holdingAfterRelease = views.isHolding
        views.endHold() // the nested code's own end: nothing is left to end

        #expect(log.nested, "page A's held post did not reach its observers")
        #expect(log.holdingInNested == false, "a hold started while the held posts went")
        #expect(log.readAtNestedChange == true, "page B's change made while the held posts went did not reach its tracker at once")
        #expect(!holdingAfterRelease, "a hold asked for during the release is holding after it")
        let lastB = trackers[1].reads.last ?? []
        #expect(lastB.contains(newBarB) && !lastB.contains(barB), "page B's tracker last read \(lastB), want its newest occlusion")
    }
}
