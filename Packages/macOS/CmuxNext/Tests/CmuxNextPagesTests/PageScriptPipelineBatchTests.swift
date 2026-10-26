import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// Frame delivery (p06-scheduler-222): on frames, the router's envelopes reach the page as one
/// script per frame; a hidden page takes none until it shows, then the latest state of each stream
/// in one script; a page message's reply keeps its turn (the envelopes before it go at once, the
/// ones after it wait for it).
@MainActor
struct PageScriptPipelineBatchTests {
    /// The test's display frame: each requested flush waits here until ``tick()``.
    final class Frames {
        private(set) var requests = 0
        private var pending: [@MainActor () -> Void] = []

        var frame: PageScriptFrame {
            { [self] flush in
                requests += 1
                pending.append(flush)
            }
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
        frames.tick()
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
        frames.tick()
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
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), clock: PageTestClock.never)
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

    @Test func aPageOpenedWithoutFramesNeverHolds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), clock: PageTestClock.never)
        let descriptor = PageDescriptor(id: "test.frames", resource: "frames", processGroup: .solo, namespaces: [])
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(!view.deliversOnFrames)
        #expect(!view.router.deliveryHeld)
    }
}
