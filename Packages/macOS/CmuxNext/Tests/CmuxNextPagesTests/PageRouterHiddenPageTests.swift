import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
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

    /// The page view's rule: out of a window or hidden is hidden; the window's occlusion counts
    /// unless an automation launch ignores it.
    @Test func nobodySeesAPageOutOfAWindowOrHidden() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        #expect(PageWebView.nobodySees(view, ignoringOcclusion: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        #expect(!PageWebView.nobodySees(view, ignoringOcclusion: true))
        window.contentView?.isHidden = true
        #expect(PageWebView.nobodySees(view, ignoringOcclusion: true))
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

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        emit = onEvent
        return PageSubscription { [weak self] in self?.emit = nil }
    }
}
