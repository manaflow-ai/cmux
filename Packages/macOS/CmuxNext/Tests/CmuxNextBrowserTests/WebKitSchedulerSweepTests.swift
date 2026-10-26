import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-323, the sweep of CmuxNextBrowser/{WebKit,PageInfo,Engine,Core,Omnibox,Screenshot}: one case per
/// migrated owner class (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitSchedulerSweepTests {
    final class Count { var value = 0 }

    /// R-notif, the tab's node: 50 progress reports of a hidden tab draw nothing; it applies once when its node
    /// shows, and a shown tab applies each report in its own turn.
    @Test func aHiddenTabsProgressAppliesOnceOnShow() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        let node = VisibilityNode(root: "test.tab", own: .hidden)
        page.adoptNode(node)
        let progress = Count()
        let observer = page.observeNavigationEvents { if case .progress = $0 { progress.value += 1 } }
        defer { page.removeNavigationObserver(observer) }
        for _ in 0..<50 { page.progressDidChange() }
        #expect(progress.value == 0, "a hidden tab applied its progress")
        #expect(node.deferredCount == 1, "a hidden tab kept more than its latest progress")
        node.set(.visible)
        #expect(progress.value == 1, "the shown tab did not apply its progress once")
        page.progressDidChange()
        #expect(progress.value == 2, "a shown tab's progress waited")
    }

    /// A page no pane shows (no node) applies its progress at once, as before.
    @Test func aPageWithNoNodeAppliesItsProgressAtOnce() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        let progress = Count()
        let observer = page.observeNavigationEvents { if case .progress = $0 { progress.value += 1 } }
        defer { page.removeNavigationObserver(observer) }
        page.progressDidChange()
        #expect(progress.value == 1)
    }

    /// A closed tab drops the progress its hidden node held.
    @Test func closingAHiddenTabDropsItsHeldProgress() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let node = VisibilityNode(root: "test.tab", own: .hidden)
        page.adoptNode(node)
        page.progressDidChange()
        page.close()
        #expect(node.deferredCount == 0)
    }

    /// R-timer: the title flush and the page-base hold are `visible` main-thread deadlines on the engine's scheduler.
    @Test func theTabsDeadlinesAreVisibleOnTheEnginesScheduler() {
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), mainWork: mainWork)
        let page = engine.makeWebKitTab()
        defer { page.close() }
        #expect(page.mainWork === mainWork)
        #expect(page.titleTimer.workClass == .visible)
        #expect(page.pageBaseHold.workClass == .visible)
    }

    /// R-notif, AppEvents: every tab's Web Inspector close watch shares the engine's one observer, and one window
    /// close is one delivery however many tabs watch.
    @Test func everyTabsInspectorWatchSharesOneObserver() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), appEvents: events)
        let first = engine.makeWebKitTab(), second = engine.makeWebKitTab()
        defer {
            first.close()
            second.close()
        }
        #expect(events.subscriberCount(NSWindow.willCloseNotification) == 2)
        center.post(name: NSWindow.willCloseNotification, object: nil)
        #expect(events.deliveries(NSWindow.willCloseNotification) == 1)
    }

    /// R-hop: a rechecked host's TLS probe runs off main, and the load's decision lands in a posted `visible` task,
    /// never in the call.
    @Test func aCertificateRecheckDecidesInAPostedTask() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let page = engine.makeWebKitTab()
        defer { page.close() }
        let url = try #require(URL(string: "https://rechecked.example/"))
        engine.certificateRechecks[page.profileID] = ["rechecked.example"]
        engine.certificateProbe = { _ in .trusted }
        final class Decision { var value: Bool? }
        let decision = Decision()
        engine.admitMainFrameLoad(url, in: page) { decision.value = $0 }
        #expect(decision.value == nil, "the load was decided in the call")
        var tries = 0
        while decision.value == nil, tries < 500 { tries += 1; try await Task.sleep(for: .milliseconds(2)) }
        #expect(decision.value == true)
        #expect(engine.needsCertificateRecheck("rechecked.example", profile: page.profileID) == false)
    }
}
