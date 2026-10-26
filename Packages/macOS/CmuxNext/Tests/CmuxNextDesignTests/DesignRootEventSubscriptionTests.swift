import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// p06-scheduler-324 (rule 9): the CmuxNextDesign root files take their notices through the app's
/// event fan-outs (``AppEvents``), one NotificationCenter observer per notice for every subscriber,
/// delivered in the notice's own turn, instead of a raw observer per object or a Task that reads
/// the notices one main-queue job later.
@MainActor
@Suite(.serialized) struct DesignRootEventSubscriptionTests {
    private static func panel(events: AppEvents) -> ActiveAppKeyPanel {
        _ = NSApplication.shared
        let panel = ActiveAppKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.nonactivatingPanel],
                                      backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.appEvents = events
        panel.isAppActive = { false }
        return panel
    }

    /// A panel shown without the keys closes once another window takes them: once, through the
    /// injected events, and its watch ends with that call or when the panel is ordered out.
    @Test func aPanelShownWithoutTheKeysHearsAnotherWindowTakeThemOnce() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let panel = Self.panel(events: events)
        var calls = 0
        panel.onKeyElsewhere = { calls += 1 }
        panel.makeKey()
        #expect(panel.isWatchingKeyElsewhere, "a panel shown without the keys does not watch for another key window")
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        center.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(calls == 1, "another window taking the keys did not reach the panel in the notice's turn")
        #expect(!panel.isWatchingKeyElsewhere)
        center.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(calls == 1, "a panel that already heard the key move heard it again")
        #expect(!events.isObserving(NSWindow.didBecomeKeyNotification), "the app's observer outlived its last subscriber")

        panel.makeKey()
        #expect(panel.isWatchingKeyElsewhere)
        panel.orderOut(nil)
        #expect(!panel.isWatchingKeyElsewhere, "a panel ordered out still watches the key window")
    }

    /// Every panel on the app's events shares one observer for the notice (A4's fan-out), however many
    /// wait for the keys.
    @Test func panelsOnTheAppsEventsShareOneObserver() {
        let events = AppEvents(center: NotificationCenter())
        let panels = (0..<3).map { _ in Self.panel(events: events) }
        for panel in panels { panel.makeKey() }
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 3)
        #expect(events.isObserving(NSWindow.didBecomeKeyNotification))
        for panel in panels { panel.orderOut(nil) }
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 0)
    }

    /// The scroll bar setting's notice re-styles the followed scroll views and tells the observers in
    /// its own turn (a Task reading the notices ran them one main-queue job later), through the one
    /// subscription the composition root keeps; released, it stops.
    @Test func theScrollBarSettingAppliesInItsNoticesTurn() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let owner = NSObject()
        var styles: [NSScroller.Style] = []
        SystemScrollers.preferredStyleOverride = .legacy
        defer { SystemScrollers.preferredStyleOverride = nil }
        SystemScrollers.observe(owner) { styles.append($0) }
        var watch: EventSubscription? = SystemScrollers.follow(settingChangesOn: events)
        center.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        #expect(styles == [.legacy], "the setting's notice did not reach the observer in its own turn")
        #expect(events.subscriberCount(NSScroller.preferredScrollerStyleDidChangeNotification) == 1)
        watch?.cancel()
        watch = nil
        center.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        #expect(styles == [.legacy], "a released subscription still re-styled the scrollers")
        withExtendedLifetime(owner) {}
    }
}
