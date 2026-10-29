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
/// (recipe R-obs), not a loop with no class: the value at the subscription is the
/// page's own read, a burst of changes is one event at the next frame with the newest value, and a
/// value equal to the first one is still an event after a change. The page's router holds the events
/// while the page is hidden, so the follower runs whether or not the page shows.
@MainActor @Suite struct SettingsPageStreamFlushTests {
    @Test func aStateStreamSendsTheNewestChangeOncePerFrame() async throws {
        let rig = PageFrameRig()
        let lists = StreamHostLists()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings, hostLists: { lists.value }, on: rig.work)
        let received = StreamEvents()
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

extension SettingsPageStreamFlushTests {
    /// Rule 9, automation case: the stream's flush is budgeted visible work, so a pending key goes
    /// first and the event waits one frame, never two.
    @Test func aStreamFlushYieldsToPendingInputForOneFrame() async throws {
        let (frames, lists, received, subscription) = try await Self.hostStream()
        defer { subscription.cancel() }
        lists.value = ["hosts": ["a"]]
        frames.inputPending = true
        frames.frame()
        #expect(received.events.isEmpty, "the flush ran ahead of the person's pending key")
        frames.frame()
        #expect(received.events == [["hosts": ["a"]]], "held one frame, never two")
    }

    /// Rule 9, person case: a change the person's own input caused is sent in the input-response
    /// pass, before the commit and before any frame, even while their next keys are pending.
    @Test func aPersonsChangeIsSentInTheInputResponsePass() async throws {
        let (frames, lists, received, subscription) = try await Self.hostStream()
        defer { subscription.cancel() }
        frames.inputPending = true
        frames.work.causes.withCause(.person) { lists.value = ["hosts": ["mine"]] }
        #expect(frames.work.causes.flushPersonCaused() == 1)
        #expect(received.events == [["hosts": ["mine"]]], "the person's change waited for a frame")
        frames.frame()
        frames.frame()
        #expect(received.events.count == 1, "the pass flushed it: no second event")
    }

    /// A host-lists stream on a frame rig, past its first frame.
    private static func hostStream() async throws -> (PageFrameRig, StreamHostLists, StreamEvents, PageSubscription) {
        let frames = PageFrameRig()
        let lists = StreamHostLists()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings, hostLists: { lists.value }, on: frames.work)
        let received = StreamEvents()
        let subscription = try await page.subscribe("cmux.settings.host.changed", filter: [:], context: PageCallContext(page: "cmux.test"),
                                                    onEvent: { received.events.append($0) })
        frames.frame()
        return (frames, lists, received, subscription)
    }
}

@Observable @MainActor
final class StreamHostLists {
    var value: JSONValue = ["hosts": []]
}

@MainActor
final class StreamEvents {
    var events: [JSONValue] = []
}
