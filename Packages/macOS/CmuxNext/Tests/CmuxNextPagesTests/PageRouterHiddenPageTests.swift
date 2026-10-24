import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// #8900 class (perf-lead.md row 16: "no hidden page may re-render"): every subscription event
/// reached a hidden page (a parked Settings, History or Home page, a page in a hidden tab) as its
/// own main-thread script evaluation, and its web process rendered it; with many hidden pages each
/// publish cost one script per page during a scroll. A page nobody can see now gets no `send` at
/// all: its events wait in order and go in one `send` when it shows, or before anything else
/// reaches the page, so nothing reorders.
@MainActor @Suite(.serialized)
struct PageRouterHiddenPageTests {
    private let descriptor = PageDescriptor(id: "cmux.hidden-test", resource: "hidden-test", namespaces: ["cmux.hidden-test."])

    /// A router with one provider stream subscribed (`sub` 1) and every `send` recorded.
    private func subscribed(_ descriptor: PageDescriptor? = nil) async throws -> (PageRouter, StreamProvider, Recorder) {
        let provider = StreamProvider()
        let page = descriptor ?? self.descriptor
        let router = PageRouter(descriptor: page, routes: [PageRoute(prefix: page.namespaces[0], provider: provider)])
        let recorder = Recorder()
        router.send = { deliveries in recorder.sends.append(deliveries.map(\.envelope)) }
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(page.namespaces[0] + "changed")])
        #expect(reply["t"]?.stringValue == "ok")
        _ = try #require(provider.emit)
        return (router, provider, recorder)
    }

    @Test func aHiddenPageGetsNoSendUntilItShowsThenOne() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        for index in 1...100 { provider.emit?(["n": .number(Double(index))]) }
        #expect(recorder.sends.isEmpty, "a hidden page got \(recorder.sends.count) script evaluations")

        #expect(router.heldCount == 100)
        router.isPageHidden = false
        #expect(recorder.sends.count == 1)
        #expect(router.heldCount == 0)
        let batch = try #require(recorder.sends.first)
        #expect(batch.compactMap { $0["seq"]?.doubleValue } == (1...100).map(Double.init))
        #expect(batch.compactMap { $0["data"]?["n"]?.doubleValue } == (1...100).map(Double.init))
    }

    @Test func aShownPageGetsEachEventAtOnce() async throws {
        let (_, provider, recorder) = try await subscribed()
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
        #expect(recorder.sends.isEmpty)
        #expect(router.publishCommand(PageNativeOp.focusContent))
        #expect(recorder.sends.count == 2)
        #expect(recorder.sends.first?.compactMap { $0["data"]?["n"]?.doubleValue } == [1, 2])
        #expect(recorder.sends.last?.first?["data"]?["command"]?.stringValue == PageNativeOp.focusContent)
    }

    /// The reply to a message the page posted reaches it after the events before it: a page that
    /// posts is awake, and the reply's place in the script FIFO comes after what it sends first.
    @Test func aPageMessageReleasesTheWaitingEventsBeforeItsReply() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        provider.emit?(["n": 1])
        #expect(recorder.sends.isEmpty)
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
            router.send = { continuation.resume(returning: $0.map(\.envelope)) }
            call = Task { @MainActor in try? await router.callPage("cmux.page.command", params: .object([:])) }
        }
        #expect(batch.map { $0["t"]?.stringValue } == ["ev", "call"])
        router.send = nil
        router.close()
        _ = await call?.value
    }

    /// An unsubscribe drops that subscription's waiting events; a close drops them all and runs
    /// their drop actions (as the script FIFO does for envelopes it had not run), so a provider
    /// can replay them to the next document.
    @Test func unsubscribeAndCloseDropTheWaitingEvents() async throws {
        let (router, provider, recorder) = try await subscribed()
        router.isPageHidden = true
        provider.emit?(["n": 1])
        _ = await router.handle(["t": "unsub", "sub": 1])
        router.isPageHidden = false
        #expect(recorder.sends.isEmpty)

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

    /// A page whose owner paces its own events (the agent pane) never holds them.
    @Test func aPageThatPacesItsOwnEventsIsNotHeld() async throws {
        let paced = PageDescriptor(id: "cmux.paced-test", resource: "paced-test", namespaces: ["cmux.paced-test."],
                                   holdsEventsWhileHidden: false)
        let (router, provider, recorder) = try await subscribed(paced)
        router.isPageHidden = true
        #expect(!router.holdsEvents)
        provider.emit?(["n": 1])
        #expect(recorder.sends.map(\.count) == [1])
    }

    /// The batch is one script; each envelope runs in its own `try`, so one page error drops none.
    @Test func aBatchIsOneScriptWithEachEnvelopeGuarded() {
        let one = PageRouter.receiveScript([["t": "ev"]])
        #expect(!one.contains("try"))
        let two = PageRouter.receiveScript([["t": "ev"], ["t": "ev"]])
        #expect(two.components(separatedBy: "window.__cmuxPageReceive(").count == 3)
        #expect(two.components(separatedBy: "try {").count == 3)
    }

    /// The page view's rule (WindowDrawPolicy's): out of a window it is hidden; in a shown window it
    /// is seen; hidden or under a hidden ancestor it is hidden again.
    @Test func thePageViewTellsItsRouterWhetherAnybodySeesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], options: .standard, chromium: nil))
        defer { view.close() }
        #expect(view.router.isPageHidden, "a page out of a window is seen")

        let drawsCovered = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true // headless hosts report every window covered
        defer { WindowDrawPolicy.drawsWhenOccluded = drawsCovered }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let pane = NSView(frame: content.bounds)
        content.addSubview(pane)
        pane.addSubview(view)
        #expect(view.router.isPageHidden == false, "a page in a window nobody covers is hidden")
        pane.isHidden = true
        #expect(view.router.isPageHidden, "a page under a hidden pane is seen")
        pane.isHidden = false
        #expect(view.router.isPageHidden == false)
        view.removeFromSuperview()
        #expect(view.router.isPageHidden)
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
        return PageSubscription {}
    }
}
