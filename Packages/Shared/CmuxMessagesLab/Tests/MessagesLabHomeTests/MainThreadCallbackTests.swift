import AppKit
import Testing
@testable import MessagesLabHome

/// The pane's main-thread callback adapters: window notifications, a later run-loop pass
/// and the local event monitors. Their owners keep them as stored values and have no `deinit` to remove them, so
/// each adapter must stop when it is released and run its work on the main actor.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadCallbackTests {
    @Test func anObservationRunsOnTheMainActorAndStopsWhenReleased() async {
        let center = NotificationCenter()
        let name = Notification.Name("MainThreadCallbackTests.ping")
        let (events, sink) = AsyncStream.makeStream(of: String.self)
        var delivered = events.makeAsyncIterator()
        var observed: MainQueueObservation? = MainQueueObservation(name, object: nil, center: center) { _ in sink.yield("observed") }
        center.post(name: name, object: nil)
        #expect(await delivered.next() == "observed")
        #expect(observed != nil)
        observed = nil
        // Main-queue deliveries keep their order: the probe's comes after any the released observation still made.
        let probe = MainQueueObservation(name, object: nil, center: center) { _ in sink.yield("probe") }
        center.post(name: name, object: nil)
        #expect(await delivered.next() == "probe", "a released observation still ran")
        withExtendedLifetime(probe) {}
    }

    @Test func aRunLoopPassRunsTheWorkAfterTheCallerOnTheMainActor() async {
        let (events, sink) = AsyncStream.makeStream(of: String.self)
        var delivered = events.makeAsyncIterator()
        MainRunLoopPass.perform(inModes: [.common]) { sink.yield("pass") }
        sink.yield("caller")
        #expect(await delivered.next() == "caller", "the work ran inline, not on a later pass")
        #expect(await delivered.next() == "pass")
    }

    /// An application-defined event through AppKit's own dequeue and dispatch, as the run loop sends it.
    private func deliverAppDefinedEvent() throws {
        let event = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, subtype: 0, data1: 4_404, data2: 0))
        NSApp.postEvent(event, atStart: true)
        if let next = NSApp.nextEvent(matching: .applicationDefined, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
    }

    @Test func aReleasedMonitorSeesNoMoreEvents() throws {
        _ = NSApplication.shared
        var seen = 0
        var monitor = ScopedEventMonitor(matching: .applicationDefined) { event in
            if event.data1 == 4_404 { seen += 1 }
            return nil
        }
        #expect(monitor != nil)
        try deliverAppDefinedEvent()
        #expect(seen == 1)
        monitor = nil
        try deliverAppDefinedEvent()
        #expect(seen == 1, "a released monitor still saw an event")
    }
}
