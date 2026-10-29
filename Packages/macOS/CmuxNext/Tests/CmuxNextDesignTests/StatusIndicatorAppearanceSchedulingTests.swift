import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// The status indicators' config follow is a ServiceObservation on the app's main-thread
/// scheduler, and its resync moments are subscriptions on the app's one AppEvents per center, not an
/// ObservationStream task and six raw observers per appearance.
@MainActor @Suite(.timeLimit(.minutes(1))) struct StatusIndicatorAppearanceSchedulingTests {
    @MainActor private final class Client: StatusIndicatorConfigClient {
        var resyncs = 0
        var changes: [StatusIndicatorConfig] = []
        func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) { changes.append(config) }
        func statusIndicatorResync() { resyncs += 1 }
    }

    @Test func resyncMomentsAreAppEventsSubscriptionsMadeOnlyWhenObserved() {
        let centers = StatusIndicatorTestFollows()
        let appearance = StatusIndicatorAppearance(windows: { [] })
        let client = Client()
        appearance.register(client)
        centers.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(client.resyncs == 0, "an appearance nobody started observed a center")
        #expect(!centers.appEvents.isObserving(NSApplication.didBecomeActiveNotification))

        centers.start(appearance)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification, NSWindow.didBecomeMainNotification] {
            #expect(centers.appEvents.subscriberCount(name) == 1, "\(name.rawValue) has no subscription")
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            #expect(centers.workspaceEvents.subscriberCount(name) == 1, "\(name.rawValue) has no subscription")
        }

        centers.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        centers.app.post(name: NSWindow.didBecomeMainNotification, object: nil)
        centers.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(client.resyncs == 3, "each moment resyncs once in its post's turn")

        // A second start makes no second set of subscriptions.
        centers.start(appearance)
        #expect(centers.appEvents.subscriberCount(NSApplication.didBecomeActiveNotification) == 1)
        withExtendedLifetime(centers) {}
    }

    @Test func observingReadsTheLiveConfigAtOnce() {
        let centers = StatusIndicatorTestFollows()
        let appearance = StatusIndicatorAppearance(windows: { [] })
        let live = StatusIndicatorConfig.current
        var stale = live
        stale.arcLength = live.arcLength + 0.1
        appearance.apply(stale)
        let client = Client()
        appearance.register(client)
        #expect(!appearance.isObserving)

        centers.start(appearance)
        #expect(appearance.isObserving)
        #expect(appearance.config == live, "the first read did not apply the config changed before the start")
        #expect(client.changes == [live], "the clients were not told once")
        withExtendedLifetime(centers) {}
    }
}
