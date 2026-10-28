import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDaemonService
import CmuxNextInput
import CmuxNextWakeups
import Foundation
import Testing

/// The cache's WebKit engine is built on the app's one `MainDeadline` placer and its one
/// ``AppEvents`` (`AppServices.mainDeadlines`, `AppServices.appEvents`), never on instances of its own.
@MainActor @Suite(.serialized) struct TabContentCacheWebKitWiringTests {
    @Test func theWebKitEngineUsesTheInjectedPlacerAndEvents() {
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let deadlines = MainDeadlineScheduler(work: mainWork)
        let events = AppEvents(center: NotificationCenter())
        let engine = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
        let cache = TabContentCache(daemon: DaemonService(), chromium: ChromiumEngineSlot(engine), fileInput: NoFileInput(), mainWork: mainWork,
                                    deadlines: deadlines, appEvents: events)
        #expect(cache.webKit.deadlines === deadlines, "the WebKit tabs' deadlines are not on the app's one placer")
        #expect(cache.webKit.mainWork === mainWork)
        #expect(cache.webKit.appEvents === events, "the WebKit tabs follow app notices on an AppEvents of their own")
        let page = cache.webKit.makeWebKitTab()
        defer { page.close() }
        #expect(events.subscriberCount(NSWindow.willCloseNotification) == 1, "the tab's inspector watch is not on the app's AppEvents")
    }
}
