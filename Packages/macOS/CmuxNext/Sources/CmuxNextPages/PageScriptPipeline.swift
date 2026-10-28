public import CmuxNextSettings
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation

/// Delivers the router's envelopes to one page in send order, and renders large ones off the main
/// actor (architecture.md 5a: the main thread does no unbounded work).
///
/// By default a small envelope with nothing queued ahead of it is rendered and evaluated at once.
/// Anything else waits in a FIFO that one drain task works through: it renders each script in a
/// `@concurrent` function and evaluates it on the main actor, one at a time, so events never
/// reorder. A ``Gate`` holds the FIFO at a point: the page's reply to a message it posted must
/// reach the page after the events sent before it and before the events sent after it, as when
/// every script was evaluated synchronously. ``reset()`` drops what is queued (the router closed:
/// those envelopes belong to cancelled subscriptions of an old document).
///
/// On frames (``deliverOnFrames(_:)``) envelopes wait for the next frame, and
/// each run of them between two gates reaches the page as one `receiveMany` script: 20 envelopes
/// in a frame are 1 evaluate. Chrome's renderer main thread takes the browser's IPC the same way,
/// with input and IPC aligned to the begin-frame (third_party/blink/renderer/platform/scheduler/
/// main_thread/main_thread_scheduler_impl.cc). A gate does not wait for the frame: what is queued
/// ahead of it goes at once, so a reply keeps its turn; ``flush()`` does the same for a built-in
/// command, a host call, a script the view runs itself (``PageWebView/callPageScript(_:arguments:)``,
/// ``PageWebView/callPageFunction(_:arguments:)``) or a hidden page's release as it shows. The frame
/// runs in the class of the highest cause that asked for it since it was asked
/// (``PageScriptFrame``).
@MainActor
final class PageScriptPipeline {
    /// Above this size an envelope (or a frame's run of them) is rendered off the main actor.
    nonisolated static let inlineBudget = PageScriptBudget(nodes: 512, stringBytes: 16 * 1024)

    private enum Item {
        case envelope(JSONValue, Drop)
        case gate(Gate)
    }

    /// A reset can report an in-flight envelope before its render task resumes. The render task
    /// still calls the drop action when it observes the generation change, so the action is
    /// explicitly one-shot to preserve the bridge's FIFO without duplicate requeues.
    final class Drop {
        private let action: @MainActor () -> Void
        private var called = false

        init(_ action: @escaping @MainActor () -> Void) { self.action = action }

        func call() {
            guard !called else { return }
            called = true
            action()
        }
    }

    /// A hold point in the FIFO: ``reached()`` returns once everything queued before it ran;
    /// nothing queued after it runs until ``open()``.
    final class Gate {
        private var isReached = false
        private var isOpen = false
        private var reachedWaiters: [OnceContinuation<Void, OnceContinuationError>] = []
        private var openWaiters: [OnceContinuation<Void, OnceContinuationError>] = []

        func reached() async {
            guard !isReached else { return }
            try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in reachedWaiters.append(waiter) }
        }

        func open() {
            markReached()
            guard !isOpen else { return }
            isOpen = true
            let waiters = openWaiters
            openWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: ()) }
        }

        fileprivate func markReached() {
            guard !isReached else { return }
            isReached = true
            let waiters = reachedWaiters
            reachedWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: ()) }
        }

        func opened() async {
            guard !isOpen else { return }
            try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in openWaiters.append(waiter) }
        }
    }

    private let deliver: @MainActor (PageDelivery) -> Void
    /// The form the next run takes, read on the main actor before it is rendered.
    private let form: @MainActor () -> PageDeliveryForm
    private let render: @Sendable ([JSONValue], PageDeliveryForm) async -> PageDelivery
    private var queue: [Item] = []
    private var head = 0
    private var drain: Task<Void, Never>?
    /// The frame envelopes wait for; nil sends each one as it comes (``deliverOnFrames(_:)``).
    private var frame: PageScriptFrame?
    /// The highest cause a frame callback was asked for with since the last one ran; nil while none
    /// is pending. Later sends ride on it, unless their cause runs sooner (``requestFrame()``).
    private var requestedCause: ObservationCause?
    /// Names the pending request: the first of its callbacks to run drains, the others find a new
    /// request (or none) and do nothing.
    private var frameRequest: UInt64 = 0
    /// The queue head is advanced before an off-actor render awaits. Keep the run's drop actions
    /// here so reset reports them before later queued envelopes, even though they are no longer in
    /// `queue[head...]`.
    private var inFlightDrops: [Drop] = []
    /// Reset opens a gate even though `head` has advanced past the item.
    private var inFlightGate: Gate?
    /// Bumped by ``reset()``: a script rendered for an older generation is not evaluated.
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - deliver: Hands one run of envelopes to the page (``PageScriptTarget/deliver(_:)``).
    ///   - form: The form the next run takes (``PageScriptTarget/deliveryForm``): data on the page push channel.
    ///   - render: Makes one run in that form (``PageDelivery/render(_:as:)``); the drain task calls it, off
    ///     the main actor by default.
    init(deliver: @escaping @MainActor (PageDelivery) -> Void,
         form: @escaping @MainActor () -> PageDeliveryForm,
         render: @escaping @Sendable ([JSONValue], PageDeliveryForm) async -> PageDelivery) {
        self.deliver = deliver
        self.form = form
        self.render = render
    }

    /// Runs rendered off the main actor (``render(_:as:)``).
    convenience init(deliver: @escaping @MainActor (PageDelivery) -> Void, form: @escaping @MainActor () -> PageDeliveryForm) {
        self.init(deliver: deliver, form: form) { envelopes, form in
            await PageScriptPipeline.render(envelopes, as: form)
        }
    }

    /// Every run as a script, run by `evaluate`.
    ///
    /// - Parameters:
    ///   - evaluate: Runs one script in the page.
    ///   - render: Makes the script of one run of envelopes (``PageRouter/receiveManyScript(_:)``).
    convenience init(evaluate: @escaping @MainActor (String) -> Void,
                     render: @escaping @Sendable ([JSONValue]) async -> String) {
        self.init(deliver: { delivery in
            if case .script(let script) = delivery { evaluate(script) }
        }, form: { .script }, render: { envelopes, _ in .script(await render(envelopes)) })
    }

    convenience init(evaluate: @escaping @MainActor (String) -> Void) {
        self.init(evaluate: evaluate) { envelopes in
            await PageScriptPipeline.render(envelopes)
        }
    }

    /// From now on envelopes wait for `frame`, and each frame's run goes to the page as one script.
    func deliverOnFrames(_ frame: PageScriptFrame) {
        self.frame = frame
        if drain == nil, head < queue.count { requestFrame() }
    }

    /// Whether envelopes wait for a frame (``deliverOnFrames(_:)``).
    var deliversOnFrames: Bool { frame != nil }

    /// True when nothing is queued or running, so a script may be evaluated at once.
    private var isIdle: Bool { drain == nil && head == queue.count }

    /// Sends `envelope` to the page after everything sent before it.
    func send(_ envelope: JSONValue, onDrop: @escaping @MainActor () -> Void = {}) {
        if frame != nil {
            queue.append(.envelope(envelope, Drop(onDrop)))
            // A running drain takes it with the rest of the queue.
            if drain == nil { requestFrame() }
            return
        }
        if isIdle, envelope.fits(Self.inlineBudget) {
            // main-actor-ok: bounded by inlineBudget; larger envelopes render off the main actor.
            // MQ12 held queue: the router holds envelopes while the page is hidden (PageRouter+Hold.swift).
            deliver(PageDelivery.render([envelope], as: form()))
            return
        }
        enqueue(.envelope(envelope, Drop(onDrop)))
    }

    /// Sends what waits for the frame now, in this turn: a built-in command or a host call was just
    /// queued, and nothing a person or the host waits on sits out a frame. A no-op without frames.
    func flush() {
        guard frame != nil, drain == nil else { return }
        drainInline()
    }

    /// A gate after everything sent so far, or nil when nothing is queued and `always` is false
    /// (a synchronous reply is already in order). On frames the envelopes ahead of it go at once
    /// (``flush()``), so a reply never waits a frame.
    func gate(always: Bool) -> Gate? {
        flush()
        guard always || !isIdle else { return nil }
        let gate = Gate()
        enqueue(.gate(gate))
        return gate
    }

    /// Drops every queued envelope and releases every gate.
    func reset() {
        generation &+= 1
        let inFlight = inFlightDrops
        inFlightDrops = []
        for drop in inFlight { drop.call() }
        inFlightGate?.open()
        inFlightGate = nil
        let pending = queue[head...]
        queue.removeAll()
        head = 0
        drain?.cancel()
        drain = nil
        for item in pending {
            switch item {
            case .envelope(_, let drop): drop.call()
            case .gate(let gate): gate.open()
            }
        }
    }

    private func enqueue(_ item: Item) {
        queue.append(item)
        startDrain()
    }

    private func startDrain() {
        guard drain == nil else { return }
        let generation = generation
        // task-owner: drains this page's FIFO; ends when it is empty or on reset()
        // main-hop-allow: the drain awaits the off-main render of large runs and the gates in FIFO order; its main parts only evaluate the rendered script in order (small runs drain inline in the frame task)
        drain = Task { @MainActor [weak self] in
            await self?.run(generation: generation)
        }
    }

    /// Asks the frame for one ``drainInline()`` with the current cause; every send until it runs
    /// shares it. A send whose cause runs sooner than the pending request's (a person's or the
    /// frontend's after a program's) asks again with its cause, and the first callback to run drains.
    private func requestFrame() {
        guard let frame else { return }
        let cause = frame.currentCause()
        if let requestedCause, cause <= requestedCause || cause < .frontend { return }
        requestedCause = cause
        let request = frameRequest
        frame.schedule(cause) { [weak self] in self?.frameDue(request) }
    }

    /// A frame callback of `request` ran: the first one drains what waits.
    private func frameDue(_ request: UInt64) {
        guard request == frameRequest else { return }
        frameRequest &+= 1
        requestedCause = nil
        // A drain a gate started meanwhile takes the queue in order.
        guard drain == nil else { return }
        drainInline()
    }

    /// Evaluates the queued runs in this turn, one script each, while each fits ``inlineBudget``;
    /// a gate or a larger run goes to the drain task, which keeps the order.
    private func drainInline() {
        while head < queue.count {
            let end = runEnd()
            guard end > head else { return startDrain() } // a gate at the head
            let run = envelopes(head..<end)
            guard JSONValue.array(run.envelopes).fits(Self.inlineBudget) else { return startDrain() }
            head = end
            // main-actor-ok: bounded by inlineBudget; larger runs render off the main actor.
            // MQ12 held queue: as above.
            deliver(PageDelivery.render(run.envelopes, as: form()))
            compact()
        }
    }

    /// The end of the run of envelopes at `head`: up to the next gate on frames, one envelope
    /// otherwise; `head` itself when a gate is there.
    private func runEnd() -> Int {
        var end = head
        while end < queue.count, case .envelope = queue[end] {
            end += 1
            if frame == nil { break }
        }
        return end
    }

    /// The envelopes of `range` and their drop actions, in order.
    private func envelopes(_ range: Range<Int>) -> (envelopes: [JSONValue], drops: [Drop]) {
        var envelopes: [JSONValue] = []
        var drops: [Drop] = []
        envelopes.reserveCapacity(range.count)
        drops.reserveCapacity(range.count)
        for index in range {
            guard case .envelope(let envelope, let drop) = queue[index] else { continue }
            envelopes.append(envelope)
            drops.append(drop)
        }
        return (envelopes, drops)
    }

    private func run(generation: UInt64) async {
        while generation == self.generation, head < queue.count {
            let end = runEnd()
            if end > head {
                let run = envelopes(head..<end)
                head = end
                inFlightDrops = run.drops
                let delivery = await render(run.envelopes, form())
                if generation != self.generation {
                    // reset() reported them already; each drop is one-shot.
                    for drop in run.drops { drop.call() }
                    return
                }
                inFlightDrops = []
                // MQ12 held queue: as above.
                deliver(delivery)
            } else if case .gate(let gate) = queue[head] {
                head += 1
                inFlightGate = gate
                gate.markReached()
                await gate.opened()
                if inFlightGate === gate { inFlightGate = nil }
                guard generation == self.generation else { return }
            }
            compact()
        }
        if generation == self.generation { drain = nil }
    }

    /// Drops the sent prefix: all of it, keeping the buffer, once the queue is empty; otherwise once
    /// it is most of the array, so a producer that keeps pace (the queue never empties) does not
    /// keep sent envelopes in memory.
    private func compact() {
        if head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= queue.count {
            queue.removeFirst(head)
            head = 0
        }
    }

    @concurrent nonisolated static func render(_ envelopes: [JSONValue]) async -> String {
        PageRouter.receiveManyScript(envelopes)
    }

    @concurrent nonisolated static func render(_ envelopes: [JSONValue], as form: PageDeliveryForm) async -> PageDelivery {
        PageDelivery.render(envelopes, as: form)
    }
}

/// A size limit for work the main actor may do on one JSON value.
nonisolated struct PageScriptBudget: Sendable {
    var nodes: Int
    var stringBytes: Int
}

/// A reply object converted off the main actor. The graph is freshly built from Foundation value
/// types (NSNull, NSNumber, String, arrays and dictionaries of them) and handed over once.
// crash-allow: the object graph is built fresh from Foundation value types and handed over once.
nonisolated struct PageReplyObject: @unchecked Sendable {
    let object: Any

    @concurrent static func convert(_ value: JSONValue) async -> PageReplyObject {
        PageReplyObject(object: value.foundationObject)
    }
}

extension JSONValue {
    /// Whether this value has at most `budget.nodes` values and `budget.stringBytes` of string
    /// UTF-8. Stops at the first value over the budget, so its cost is bounded by the budget.
    nonisolated func fits(_ budget: PageScriptBudget) -> Bool {
        var nodes = budget.nodes
        var bytes = budget.stringBytes
        return fits(nodes: &nodes, bytes: &bytes)
    }

    private nonisolated func fits(nodes: inout Int, bytes: inout Int) -> Bool {
        nodes -= 1
        guard nodes >= 0 else { return false }
        switch self {
        case .null, .bool, .number:
            return true
        case .string(let text):
            bytes -= text.utf8.count
            return bytes >= 0
        case .array(let items):
            for item in items where !item.fits(nodes: &nodes, bytes: &bytes) { return false }
            return true
        case .object(let members):
            for (key, value) in members {
                bytes -= key.utf8.count
                guard bytes >= 0, value.fits(nodes: &nodes, bytes: &bytes) else { return false }
            }
            return true
        }
    }
}
