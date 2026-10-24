import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// #8900 class (perf-lead.md row 16, row 23 (c)): every subscription event reached a hidden page as
/// its own main-thread script evaluation, and its web process rendered it. A page nobody can see
/// now gets no `send` at all; its events wait in order and go in one `send` when it shows, or
/// before anything else reaches the page, so nothing reorders.
@MainActor
struct PageRouterHiddenPageTests {
    private let descriptor = PageDescriptor(id: "cmux.hidden-test", resource: "hidden-test", namespaces: ["cmux.hidden-test."])

    /// A router with one provider stream subscribed (`sub` 1) and every `send` recorded.
    private func subscribed() async throws -> (PageRouter, StreamProvider, Recorder) {
        let provider = StreamProvider()
        let router = PageRouter(descriptor: descriptor, routes: [PageRoute(prefix: "cmux.hidden-test.", provider: provider)])
        let recorder = Recorder()
        router.send = { recorder.sends.append($0) }
        let reply = await router.handle(["t": "sub", "id": 1, "stream": "cmux.hidden-test.changed"])
        #expect(reply["t"]?.stringValue == "ok")
        _ = try #require(provider.emit)
        return (router, provider, recorder)
    }

    @Test func aHiddenPageGetsNoSendUntilItShowsThenOne() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        for index in 1...100 { provider.emit?(["n": .number(Double(index))]) }
        #expect(recorder.sends.isEmpty)
        #expect(router.heldCount == 100)

        router.isPageHidden = false
        #expect(recorder.sends.count == 1)
        let batch = try #require(recorder.sends.first)
        #expect(batch.compactMap { $0["seq"]?.doubleValue } == (1...100).map(Double.init))
        #expect(batch.compactMap { $0["data"]?["n"]?.doubleValue } == (1...100).map(Double.init))
        #expect(router.heldCount == 0)
    }

    @Test func aShownPageGetsEachEventAtOnce() async throws {
        let (router, provider, recorder) = try await subscribed()
        provider.emit?(["n": 1])
        provider.emit?(["n": 2])
        #expect(recorder.sends.map(\.count) == [1, 1])
    }

    /// A command is the person's own action: it goes at once, after the events that waited.
    @Test func aCommandGoesAtOnceAfterTheWaitingEvents() async throws {
        let (router, provider, recorder) = try await subscribed()
        _ = await router.handle(["t": "sub", "id": 2, "stream": .string(PageNativeOp.pageCommand)])
        router.isPageHidden = true
        provider.emit?(["n": 1])
        provider.emit?(["n": 2])
        #expect(router.publishCommand(PageNativeOp.focusContent))
        #expect(recorder.sends.count == 2)
        #expect(recorder.sends.first?.compactMap { $0["data"]?["n"]?.doubleValue } == [1, 2])
        #expect(recorder.sends.last?.first?["data"]?["command"]?.stringValue == PageNativeOp.focusContent)
    }

    /// The reply to a message the page posted reaches it after the events before it.
    @Test func aPageMessageReleasesTheWaitingEventsBeforeItsReply() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        provider.emit?(["n": 1])
        _ = await router.handle(["t": "unsub", "sub": 99])
        #expect(recorder.sends.map(\.count) == [1])
    }

    /// A host call carries the waiting events ahead of it, in the same `send`.
    @Test func aHostCallCarriesTheWaitingEventsAheadOfIt() async throws {
        let (router, provider, _) = try await subscribed()
        router.isPageHidden = true
        provider.emit?(["n": 1])
        var call: Task<JSONValue?, Never>?
        let batch: [JSONValue] = await withCheckedContinuation { continuation in
            router.send = { continuation.resume(returning: $0) }
            call = Task { @MainActor in try? await router.callPage("cmux.page.command", params: .object([:])) }
        }
        #expect(batch.map { $0["t"]?.stringValue } == ["ev", "call"])
        router.send = nil
        router.close()
        _ = await call?.value
    }

    @Test func closeAndUnsubscribeDropTheWaitingEvents() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        provider.emit?(["n": 1])
        _ = await router.handle(["t": "unsub", "sub": 1])
        #expect(recorder.sends.isEmpty)
        #expect(router.heldCount == 0)

        let (second, other, secondRecorder) = try await subscribed()
        second.isPageHidden = true
        other.emit?(["n": 1])
        second.close()
        second.isPageHidden = false
        #expect(secondRecorder.sends.isEmpty)
    }

    /// A reset reports what the page never got, so a provider that hands its events to the next
    /// page (the agent pane) loses none: a hidden page's waiting events too, oldest first.
    @Test func closeReportsTheWaitingEventsAsDropped() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        provider.emit?(["n": 1])
        provider.emit?(["n": 2])
        router.close()
        #expect(recorder.sends.isEmpty)
        #expect(provider.dropped.compactMap { $0["n"]?.doubleValue } == [1, 2])
    }

    /// The waiting events go in one `sendWithDrop`; its one drop action reports each of them.
    @Test func aBatchsDropReportsEveryEventInIt() async throws {
        let (router, provider, _) = try await subscribed()
        var drops: [@MainActor () -> Void] = []
        router.sendWithDrop = { _, onDrop in drops.append(onDrop) }
        router.isPageHidden = true
        provider.emit?(["n": 1])
        provider.emit?(["n": 2])
        router.isPageHidden = false
        #expect(drops.count == 1)
        drops.forEach { $0() }
        #expect(provider.dropped.compactMap { $0["n"]?.doubleValue } == [1, 2])
    }

    /// A provider's events sent inside `subscribe` wait for the reply and then go in order; the
    /// events after the reply go straight to the page. The guard after `subscribe` had its two
    /// cases swapped (#24617): held events were dropped, and with none held every later event
    /// waited for a flush task.
    @Test func eventsSentDuringSubscribeFollowTheReplyAndLaterOnesGoAtOnce() async throws {
        let provider = StreamProvider()
        provider.duringSubscribe = [["n": 1], ["n": 2]]
        let router = PageRouter(descriptor: descriptor, routes: [PageRoute(prefix: "cmux.hidden-test.", provider: provider)])
        let recorder = Recorder()
        let (sent, sink) = AsyncStream<[JSONValue]>.makeStream()
        router.send = { recorder.sends.append($0); sink.yield($0) }
        let reply = await router.handle(["t": "sub", "id": 1, "stream": "cmux.hidden-test.changed"])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(recorder.sends.isEmpty, "an event sent during subscribe reached the page before the reply")
        var flushed: [Double] = []
        for await batch in sent {
            flushed += batch.compactMap { $0["data"]?["n"]?.doubleValue }
            if flushed.count >= 2 { break }
        }
        #expect(flushed == [1, 2])
        provider.emit?(["n": 3])
        #expect(recorder.sends.last?.compactMap { $0["data"]?["n"]?.doubleValue } == [3])
    }

    @Test func eventsAfterAReplyWithNothingHeldGoAtOnce() async throws {
        let (_, provider, recorder) = try await subscribed()
        provider.emit?(["n": 1])
        #expect(recorder.sends.map(\.count) == [1], "an event after the reply waited for a flush")
    }

    /// A busy stream behind another tab costs one `send` per ``PageRouter/heldLimit`` events, not
    /// unbounded memory.
    @Test func aBusyHiddenStreamGoesInBatchesOfTheLimit() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        for index in 0..<(PageRouter.heldLimit * 2 + 3) { provider.emit?(["n": .number(Double(index))]) }
        #expect(recorder.sends.map(\.count) == [PageRouter.heldLimit, PageRouter.heldLimit])
        #expect(router.heldCount == 3)
    }

    /// The batch is one script; each envelope runs in its own `try`, so one page error drops none.
    @Test func aBatchIsOneScriptWithEachEnvelopeGuarded() {
        let one = PageRouter.receiveScript([["t": "ev"]])
        #expect(!one.contains("try"))
        let two = PageRouter.receiveScript([["t": "ev"], ["t": "ev"]])
        #expect(two.components(separatedBy: "window.__cmuxPageReceive(").count == 3)
        #expect(two.components(separatedBy: "try {").count == 3)
    }

    /// The page view's rule: out of a window or hidden is hidden.
    @Test func nobodySeesAPageOutOfAWindowOrHidden() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        #expect(PageWebView.nobodySees(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        #expect(!PageWebView.nobodySees(view))
        window.contentView?.isHidden = true
        #expect(PageWebView.nobodySees(view))
    }
}

/// The page view tells its router: a page out of a window holds its events, a page in a shown
/// window does not, and a page whose owner paces its own events (the agent pane) never holds.
@MainActor
struct PageWebViewHiddenEventsTests {
    @Test func aPageViewHoldsItsEventsOnlyWhileNobodySeesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.hidden-events", resource: "hidden-events", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil,
                                            lowPowerMode: LowPowerMode(enabled: false)))
        defer { view.close() }
        #expect(view.router.isPageHidden, "a page out of a window holds its events")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.isHidden = true
        #expect(view.router.isPageHidden, "a hidden page holds its events")
        view.holdsEventsWhileHidden = false
        #expect(!view.router.isPageHidden, "a page that paces its own events never holds them")
    }
}

@MainActor
private final class Recorder {
    var sends: [[JSONValue]] = []
}

/// A provider with one stream whose events the test emits.
@MainActor
private final class StreamProvider: PageProvider {
    var emit: (@MainActor (JSONValue) -> Void)?
    /// Events `subscribe` sends before it returns (its current state).
    var duringSubscribe: [JSONValue] = []
    /// Event data the router reported as never delivered, in report order.
    var dropped: [JSONValue] = []

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        emit = onEvent
        for data in duringSubscribe { onEvent(data) }
        return PageSubscription { [weak self] in self?.emit = nil }
    }

    func eventDeliveryDropped(stream: String, data: JSONValue, publicationID: UInt64?) {
        dropped.append(data)
    }
}
