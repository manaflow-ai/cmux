import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
@testable import CmuxNextWakeups
import Testing

/// The claim's fallback is a ``MainDeadline`` on the page's deadline scheduler: a person waits on
/// the claimed page (opening Settings), so the fallback is visible work at its due time, and a claim the document never
/// answers reloads when that deadline's task runs, not before. The claimed page is a preload of the app's one preload
/// slot, on a Chromium page whose document the test answers for.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageClaimDeadlineTests {
    @Test func anUnansweredClaimReloadsInTheVisibleTaskOfItsDeadline() async throws {
        let base = try PagePreloadPageTests()
        defer { try? FileManager.default.removeItem(at: base.root) }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        let host = base.makeHost(hosting)
        let parking = PagePreloadParkingView(frame: .zero)
        window.contentView?.addSubview(parking)
        let view = try base.preload(host, in: parking)
        defer { host.close(view) }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        page.onEvent?(.devTools(PagePreloadPageTests.frameNavigated))
        page.onEvent?(.devTools(PagePreloadPageTests.loadEventFired))
        #expect(view.loaded && !view.isClaimed)

        // The parked document loaded, but it never answers the claim's page call.
        view.bindClaim(routes: [], route: nil)
        let deadline = view.claimState.deadline
        #expect(view.claimState.pending)
        #expect(deadline.isScheduled)
        #expect(deadline.workClass == .visible, "a claim a person waits on is not visible work")
        await Task.yield()
        #expect(view.lastClaim == nil, "the claim ended before its deadline")

        // The wake posts the fallback and the frame runs it: the claim times out and the document reloads.
        base.pageDeadlines.fire()
        #expect(view.lastClaim?.path == .timedOut)
        #expect(!view.claimState.pending)
        #expect(!deadline.isScheduled)
    }
}
