import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
@testable import CmuxNextWakeups
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// A Settings page state stream follows its state through a ServiceObservation on the app's scheduler
/// (p06-scheduler-309, recipe R-obs), not a loop with no class: the value at the subscription is the
/// page's own read, a burst of changes is one event at the next frame with the newest value, and a
/// value equal to the first one is still an event after a change. The page's router holds the events
/// while the page is hidden, so the follower runs whether or not the page shows.
@MainActor @Suite struct SettingsPageStreamFlushTests {
    @Test func aStateStreamSendsTheNewestChangeOncePerFrame() async throws {
        let rig = StreamFrames()
        let lists = HostLists()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings, hostLists: { lists.value }, on: rig.work)
        let received = ReceivedEvents()
        let subscription = try await page.subscribe("cmux.settings.host.changed", filter: [:], context: PageCallContext(page: "cmux.test"),
                                                    onEvent: { received.events.append($0) })
        defer { subscription.cancel() }
        let first = lists.value

        rig.frame()
        #expect(received.events.isEmpty, "the subscription's own value is the page's read, not an event")

        lists.value = ["hosts": ["a"]]
        lists.value = ["hosts": ["b"]]
        #expect(received.events.isEmpty, "a change waits for its frame")
        rig.frame()
        #expect(received.events == [["hosts": ["b"]]], "two changes in one turn are one event with the newest value")

        lists.value = first
        rig.frame()
        #expect(received.events.last == first, "a return to the first value is a change from the last event")
        #expect(received.events.count == 2)

        subscription.cancel()
        lists.value = ["hosts": ["c"]]
        rig.frame()
        #expect(received.events.count == 2, "a cancelled stream sends nothing")
    }
}

@Observable @MainActor
private final class HostLists {
    var value: JSONValue = ["hosts": []]
}

@MainActor
private final class ReceivedEvents {
    var events: [JSONValue] = []
}

/// The app's scheduler with a display link the test fires: a posted flush waits for ``frame()``.
@MainActor
private final class StreamFrames {
    let work: MainWorkScheduler
    private let uptime: StreamUptime
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let uptime = StreamUptime()
        self.uptime = uptime
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read), ledger: WakeupLedger()) { _ in StreamLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    func frame() {
        uptime.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }
}

@MainActor
private final class StreamUptime {
    var now: UInt64 = 1_000_000_000
    // Strong: the scheduler may read it after the test returned.
    var read: () -> UInt64 { { [self] in self.now } }
}

private final class StreamLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
