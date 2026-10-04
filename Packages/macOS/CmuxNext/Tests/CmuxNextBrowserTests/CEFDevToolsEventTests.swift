import Foundation
import Testing
@testable import CmuxNextBrowser

/// DevTools protocol events (shim kind 32) reach a tab's subscribers, and
/// the shim is told to forward them only while someone subscribes.
@Suite struct CEFDevToolsEventTests {
    @Test func shimEventDecodesMethodAndParams() {
        let event = CEFShimEvent(kind: 32, browser: 7, request: 0, a: 0, b: 0, s1: "Runtime.bindingCalled", s2: #"{"name":"x"}"#)
        #expect(event == .devToolsEvent(browser: 7, method: "Runtime.bindingCalled", params: #"{"name":"x"}"#))
        #expect(event.browserID == 7)
    }

    @Test func fanoutDeliversToEverySubscriberAndReportsFirstAndLast() async {
        let fanout = CEFDevToolsEventFanout()
        let changes = Changes()
        let first = fanout.subscribe { changes.record($0) }
        let second = fanout.subscribe { changes.record($0) }
        #expect(changes.values == [true])
        fanout.deliver(BrowserDevToolsEvent(method: "A", params: "{}"))
        fanout.finishAll()
        var firstEvents: [String] = []
        for await event in first { firstEvents.append(event.method) }
        var secondEvents: [String] = []
        for await event in second { secondEvents.append(event.method) }
        #expect(firstEvents == ["A"])
        #expect(secondEvents == ["A"])
        #expect(!fanout.hasSubscribers)
    }

    @Test func endingTheLastStreamTurnsForwardingOff() async {
        let fanout = CEFDevToolsEventFanout()
        let changes = Changes()
        let task = Task {
            for await _ in fanout.subscribe(changed: { changes.record($0) }) {}
        }
        while changes.values.isEmpty { await Task.yield() }
        task.cancel()
        await task.value
        while changes.values.count < 2 { await Task.yield() }
        #expect(changes.values == [true, false])
        #expect(!fanout.hasSubscribers)
    }
}

private final class Changes {
    var values: [Bool] = []
    func record(_ on: Bool) { values.append(on) }
}
