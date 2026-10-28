import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Frame delivery: on frames, the router's envelopes reach the page as one
/// script per frame; a hidden page takes none until it shows, then the latest state of each stream
/// in one script; a page message's reply keeps its turn (the envelopes before it go at once, the
/// ones after it wait for it).
@MainActor
struct PageScriptPipelineBatchTests {
    /// The test's display frame: each requested flush waits here until ``tick()``.
    final class Frames {
        private(set) var requests = 0
        /// The cause of each request, in order.
        private(set) var causes: [ObservationCause] = []
        /// The cause of the change being made now.
        var cause = ObservationCause.program
        private var pending: [@MainActor () -> Void] = []

        var frame: PageScriptFrame {
            PageScriptFrame(currentCause: { [self] in cause }, schedule: { [self] cause, flush in
                requests += 1
                causes.append(cause)
                pending.append(flush)
            })
        }

        var waiting: Int { pending.count }

        func tick() {
            let due = pending
            pending.removeAll()
            for flush in due { flush() }
        }
    }

    /// The scripts the page ran, in order, and the envelopes each one carried.
    final class Page {
        private(set) var scripts: [String] = []
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func evaluate(_ script: String) {
            scripts.append(script)
            guard let waiter, scripts.count >= waiter.count else { return }
            self.waiter = nil
            waiter.continuation.resume()
        }

        /// Returns once `count` scripts ran.
        func waitForScripts(_ count: Int) async {
            guard scripts.count < count else { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }

        /// The envelopes `scripts[index]` delivers, in order.
        func envelopes(_ index: Int) -> [JSONValue] {
            PageScriptPipelineBatchTests.envelopes(in: scripts[index])
        }
    }

    /// Parses a ``PageRouter/receiveScript(_:)`` or ``PageRouter/receiveManyScript(_:)`` back.
    static func envelopes(in script: String) -> [JSONValue] {
        let single = "window.__cmuxPageReceive && window.__cmuxPageReceive("
        let json: Substring
        if script.hasPrefix(single) {
            json = script.dropFirst(single.count).dropLast(2)
        } else if let start = script.range(of: "})(") {
            json = script[start.upperBound...].dropLast(2)
        } else {
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]),
              let value = JSONValue(foundation: object) else { return [] }
        return script.hasPrefix(single) ? [value] : value.arrayValue ?? []
    }

    private static func event(_ n: Int) -> JSONValue {
        ["t": "ev", "sub": 1, "seq": .number(Double(n + 1)), "data": ["n": .number(Double(n))]]
    }

    private func makePipeline(_ page: Page, _ frames: Frames) -> PageScriptPipeline {
        let pipeline = PageScriptPipeline { script in page.evaluate(script) }
        pipeline.deliverOnFrames(frames.frame)
        return pipeline
    }

    // MARK: One evaluate per frame

    @Test func twentyEnvelopesInAFrameAreOneEvaluate() {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        let sent = (0..<20).map(Self.event)
        for envelope in sent { pipeline.send(envelope) }
        #expect(page.scripts.isEmpty)
        #expect(frames.requests == 1)
        frames.tick()
        #expect(page.scripts.count == 1)
        #expect(page.envelopes(0) == sent)
        #expect(page.scripts[0].contains("__cmuxPageReceiveMany"))
    }

    // MARK: The frame's cause

    /// A program's send asked for the frame first; the person's send in the same frame asks again
    /// with its cause, so the frame does not run in the program's budgeted class. One drain runs.
    @Test func aPersonsSendAfterAProgramsInTheSameFrameAsksAgainWithItsCause() {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        frames.cause = .program
        pipeline.send(Self.event(0))
        frames.cause = .person
        pipeline.send(Self.event(1))
        // A lower cause rides on the request it finds.
        frames.cause = .automation
        pipeline.send(Self.event(2))
        #expect(frames.causes == [.program, .person])
        frames.tick()
        #expect(page.scripts.count == 1)
        #expect(page.envelopes(0) == [Self.event(0), Self.event(1), Self.event(2)])
        // The next frame starts from the next send's cause.
        frames.cause = .program
        pipeline.send(Self.event(3))
        #expect(frames.causes == [.program, .person, .program])
    }

    /// The same mix through the app's queue (`pages.scripts`, budgeted `visible`): the person's send
    /// puts the frame on the unbudgeted path, so it does not wait for the class budget.
    @Test func aPersonsSendAfterAProgramsTakesTheUnbudgetedPath() {
        let work = MainWorkScheduler.testing(ledger: WakeupLedger()) { _ in StillLink() }
        let queue = FrameBatchQueue(owner: "pages.scripts", budgeted: .visible, on: work)
        let page = Page()
        let pipeline = PageScriptPipeline { script in page.evaluate(script) }
        pipeline.deliverOnFrames(queue.pageScriptFrame(causes: work.causes))
        pipeline.send(Self.event(0))
        #expect(queue.unbudgetedCount == 0)
        work.causes.withCause(.person) { pipeline.send(Self.event(1)) }
        #expect(queue.unbudgetedCount == 1, "the person's change asked for the frame")
        #expect(page.scripts.isEmpty)
    }

    @Test func withoutFramesEachEnvelopeIsItsOwnEvaluate() {
        let page = Page()
        let pipeline = PageScriptPipeline { script in page.evaluate(script) }
        for envelope in (0..<20).map(Self.event) { pipeline.send(envelope) }
        #expect(page.scripts.count == 20)
        #expect(page.scripts[0] == PageRouter.receiveScript(Self.event(0)))
    }

    @Test func aLargeRunRendersOffTheMainActorAsOneEvaluate() async {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        let large: JSONValue = ["t": "ev", "sub": 1, "seq": 1, "data": .string(String(repeating: "x", count: 20_000))]
        pipeline.send(large)
        pipeline.send(Self.event(1))
        frames.tick()
        await page.waitForScripts(1)
        #expect(page.scripts.count == 1)
        #expect(page.envelopes(0) == [large, Self.event(1)])
    }

    @Test func aFlushSendsTheFrameNow() {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        pipeline.send(Self.event(0))
        pipeline.send(Self.event(1))
        pipeline.flush()
        #expect(page.scripts.count == 1)
        #expect(page.envelopes(0) == [Self.event(0), Self.event(1)])
        // The frame asked for before the flush finds nothing left.
        frames.tick()
        #expect(page.scripts.count == 1)
    }

    @Test func aResetDropsTheFramesEnvelopes() {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        var drops: [Int] = []
        pipeline.send(Self.event(0)) { drops.append(0) }
        pipeline.send(Self.event(1)) { drops.append(1) }
        pipeline.reset()
        #expect(drops == [0, 1])
        frames.tick()
        #expect(page.scripts.isEmpty)
    }

    // MARK: Gate replies keep their turn

    @Test func aReplySendsWhatIsAheadOfItInItsTurn() {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        pipeline.send(Self.event(0))
        pipeline.send(Self.event(1))
        // The events ahead of a small reply go in this turn, so the reply needs no gate.
        #expect(pipeline.gate(always: false) == nil)
        #expect(frames.waiting == 1)
        #expect(page.scripts.count == 1)
        #expect(page.envelopes(0) == [Self.event(0), Self.event(1)])
        frames.tick()
        #expect(page.scripts.count == 1)
    }

    @Test func aLargeReplysGateHoldsWhatIsSentAfterIt() async {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        pipeline.send(Self.event(0))
        pipeline.send(Self.event(1))
        let gate = pipeline.gate(always: true)
        #expect(gate != nil)
        await gate?.reached()
        // The frame never ticked: the reply did not wait for it.
        #expect(page.scripts.count == 1)
        #expect(page.envelopes(0) == [Self.event(0), Self.event(1)])
        // Sent after the reply's gate: reaches the page only after the reply.
        pipeline.send(Self.event(2))
        frames.tick()
        #expect(page.scripts.count == 1)
        gate?.open()
        await page.waitForScripts(2)
        #expect(page.envelopes(1) == [Self.event(2)])
    }

    @Test func aGateBehindALargeRunKeepsItsTurn() async {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        let large: JSONValue = ["t": "ev", "sub": 1, "seq": 1, "data": .string(String(repeating: "x", count: 20_000))]
        pipeline.send(large)
        let gate = pipeline.gate(always: false)
        #expect(gate != nil)
        pipeline.send(Self.event(1))
        await gate?.reached()
        #expect(page.scripts.count == 1)
        #expect(page.envelopes(0) == [large])
        gate?.open()
        await page.waitForScripts(2)
        #expect(page.envelopes(1) == [Self.event(1)])
    }

    @Test func anIdlePipelineOnFramesNeedsNoGate() {
        let pipeline = makePipeline(Page(), Frames())
        #expect(pipeline.gate(always: false) == nil)
    }

    // MARK: Hidden pages

    private func makeRouter(_ provider: PageRouterFrozenDeliveryTests.StreamProvider, _ pipeline: PageScriptPipeline) -> PageRouter {
        let router = PageRouter(descriptor: PageRouterFrozenDeliveryTests.descriptor,
                                routes: [PageRoute(prefix: "cmux.held.", provider: provider)])
        router.send = { envelope in pipeline.send(envelope) }
        router.sendWithDrop = { envelope, onDrop in pipeline.send(envelope, onDrop: onDrop) }
        router.deliverNow = { pipeline.flush() }
        return router
    }

    @Test func aHiddenPageTakesNoStateEventsThenTheLastOneOnShow() async {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        let provider = PageRouterFrozenDeliveryTests.StreamProvider(["cmux.held.state": .latest])
        let router = makeRouter(provider, pipeline)
        _ = await router.handle(["t": "sub", "id": 1, "stream": "cmux.held.state"])
        router.holdDelivery(.hidden)
        provider.emit("cmux.held.state", 0..<100)
        #expect(frames.requests == 0)
        #expect(page.scripts.isEmpty)
        router.releaseDelivery(.hidden)
        // In the show's turn, not on a later frame.
        #expect(page.scripts.count == 1)
        frames.tick()
        #expect(page.scripts.count == 1)
        let delivered = page.envelopes(0)
        #expect(delivered.count == 1)
        #expect(delivered.first?["data"]?["n"] == .number(99))
        #expect(delivered.first?["seq"] == .number(1))
    }

    @Test func aHiddenStreamOverflowsIntoAGap() async {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        let provider = PageRouterFrozenDeliveryTests.StreamProvider(["cmux.held.log": .queue(4)])
        let router = makeRouter(provider, pipeline)
        _ = await router.handle(["t": "sub", "id": 1, "stream": "cmux.held.log"])
        router.holdDelivery(.hidden)
        provider.emit("cmux.held.log", 0..<10)
        router.releaseDelivery(.hidden)
        #expect(page.scripts.count == 1)
        let events = page.envelopes(0).first?["events"]?.arrayValue ?? []
        #expect(events.compactMap { $0["data"]?["n"]?.doubleValue } == [6, 7, 8, 9])
        #expect(events.first?["gap"] == .bool(true))
        #expect(provider.dropped.count == 6)
    }

    @Test func theHiddenHoldAndTheLifecycleHoldEachKeepTheRouterHeld() async {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        let provider = PageRouterFrozenDeliveryTests.StreamProvider(["cmux.held.state": .latest])
        let router = makeRouter(provider, pipeline)
        _ = await router.handle(["t": "sub", "id": 1, "stream": "cmux.held.state"])
        router.holdDelivery(.hidden)
        router.holdDelivery()
        provider.emit("cmux.held.state", 0..<3)
        // Thawed (an ordered stream filled, a command) while still hidden: still held.
        router.releaseDelivery()
        #expect(router.deliveryHeld)
        router.releaseDelivery(.hidden)
        #expect(!router.deliveryHeld)
        #expect(page.envelopes(0).first?["data"]?["n"] == .number(2))
    }

    @Test func aHostCallToAHiddenPageGoesInItsTurn() async throws {
        let page = Page()
        let frames = Frames()
        let pipeline = makePipeline(page, frames)
        let router = makeRouter(PageRouterFrozenDeliveryTests.StreamProvider([:]), pipeline)
        router.holdDelivery(.hidden)
        let call = Task { @MainActor in try await router.callPage("cmux.page.test", params: .object([:])) }
        await page.waitForScripts(1)
        #expect(frames.waiting <= 1)
        let envelope = try #require(page.envelopes(0).first)
        #expect(envelope["t"] == "call")
        _ = await router.handle(["t": "ok", "id": envelope["id"] ?? .null, "value": "done"])
        #expect(try await call.value == "done")
    }

    // MARK: The page view

    @Test func aPageOpenedOnFramesHoldsWhileHiddenAndReleasesWhenShown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never)
        let frames = Frames()
        host.scriptFrames = frames.frame
        let descriptor = PageDescriptor(id: "test.frames", resource: "frames", processGroup: .solo, namespaces: [])
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(view.deliversOnFrames)
        // In no window: hidden.
        #expect(view.router.deliveryHeld)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(!view.router.deliveryHeld)
        view.isHidden = true
        #expect(view.router.deliveryHeld)
        view.isHidden = false
        #expect(!view.router.deliveryHeld)
    }

    /// A page script the view runs itself goes after the envelopes sent before it: they reach the
    /// page first, in the call's turn, not on the next frame.
    @Test func aPageScriptGoesAfterTheEnvelopesSentBeforeIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let hosting = FakeChromiumHosting()
        let descriptor = PageDescriptor(id: "test.frames", resource: "frames", processGroup: .solo, namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/start", chromium: hosting))
        defer { view.close() }
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        let frames = Frames()
        view.deliverOnFrames(frames.frame)
        let log = OrderLog()
        view.scriptTarget.bridge = OrderBridge(log: log)
        page.rendererEvaluate = { _ in
            log.entries.append("call")
            return "1"
        }
        view.scripts.send(Self.event(0))
        #expect(log.entries.isEmpty)
        _ = try await view.callPageScript("return 1;")
        view.scripts.send(Self.event(1))
        _ = await view.callPageFunction("return 1;")
        #expect(log.entries == ["envelope", "call", "envelope", "call"])
    }

    @Test func aPageOpenedWithoutFramesNeverHolds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never)
        let descriptor = PageDescriptor(id: "test.frames", resource: "frames", processGroup: .solo, namespaces: [])
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(!view.deliversOnFrames)
        #expect(!view.router.deliveryHeld)
    }
}

/// A link that never fires: the queue's frames are not run.
@MainActor private final class StillLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// The order a page saw scripts in: ``OrderBridge``'s envelopes and the view's own calls.
@MainActor private final class OrderLog {
    var entries: [String] = []
}

/// A bridge that logs each router script it runs as `envelope`.
@MainActor private final class OrderBridge: PageHostBridge {
    let engine = PageHostEngine.cef
    let log: OrderLog

    init(log: OrderLog) { self.log = log }

    func install(_ handler: @escaping PageHostHandler) {}
    func evaluate(_ script: String) { log.entries.append("envelope") }
    func uninstall() {}
}
