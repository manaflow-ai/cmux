public import CmuxNextSettings
import Foundation

/// Delivers the router's envelopes to one page in send order, and renders large ones off the main
/// actor (architecture.md 5a: the main thread does no unbounded work).
///
/// A small envelope with nothing queued ahead of it is rendered and evaluated at once, as before.
/// Anything else waits in a FIFO that one drain task works through: it renders each script in a
/// `@concurrent` function and evaluates it on the main actor, one at a time, so events never
/// reorder. A ``Gate`` holds the FIFO at a point: the page's reply to a message it posted must
/// reach the page after the events sent before it and before the events sent after it, as when
/// every script was evaluated synchronously. ``reset()`` drops what is queued (the router closed:
/// those envelopes belong to cancelled subscriptions of an old document).
@MainActor
final class PageScriptPipeline {
    /// Above this size an envelope is rendered off the main actor.
    nonisolated static let inlineBudget = PageScriptBudget(nodes: 512, stringBytes: 16 * 1024)

    private enum Item {
        case envelope(JSONValue)
        case gate(Gate)
    }

    /// A hold point in the FIFO: ``reached()`` returns once everything queued before it ran;
    /// nothing queued after it runs until ``open()``.
    final class Gate {
        private var isReached = false
        private var isOpen = false
        private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func reached() async {
            guard !isReached else { return }
            await withCheckedContinuation { reachedWaiters.append($0) }
        }

        func open() {
            markReached()
            guard !isOpen else { return }
            isOpen = true
            let waiters = openWaiters
            openWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        fileprivate func markReached() {
            guard !isReached else { return }
            isReached = true
            let waiters = reachedWaiters
            reachedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        fileprivate func opened() async {
            guard !isOpen else { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }
    }

    private let evaluate: @MainActor (String) -> Void
    private var queue: [Item] = []
    private var head = 0
    private var drain: Task<Void, Never>?
    /// Bumped by ``reset()``: a script rendered for an older generation is not evaluated.
    private var generation: UInt64 = 0

    init(evaluate: @escaping @MainActor (String) -> Void) {
        self.evaluate = evaluate
    }

    /// True when nothing is queued or running, so a script may be evaluated at once.
    private var isIdle: Bool { drain == nil && head == queue.count }

    /// Sends `envelope` to the page after everything sent before it.
    func send(_ envelope: JSONValue) {
        if isIdle, envelope.fits(Self.inlineBudget) {
            // main-actor-ok: bounded by inlineBudget; larger envelopes render off the main actor.
            evaluate(PageRouter.receiveScript(envelope))
            return
        }
        enqueue(.envelope(envelope))
    }

    /// A gate after everything sent so far, or nil when nothing is queued and `always` is false
    /// (a synchronous reply is already in order).
    func gate(always: Bool) -> Gate? {
        guard always || !isIdle else { return nil }
        let gate = Gate()
        enqueue(.gate(gate))
        return gate
    }

    /// Drops every queued envelope and releases every gate.
    func reset() {
        generation &+= 1
        let pending = queue[head...]
        queue.removeAll()
        head = 0
        drain?.cancel()
        drain = nil
        for case .gate(let gate) in pending { gate.open() }
    }

    private func enqueue(_ item: Item) {
        queue.append(item)
        guard drain == nil else { return }
        let generation = generation
        // task-owner: drains this page's FIFO; ends when it is empty or on reset()
        drain = Task { @MainActor [weak self] in
            await self?.run(generation: generation)
        }
    }

    private func run(generation: UInt64) async {
        while generation == self.generation, head < queue.count {
            let item = queue[head]
            head += 1
            switch item {
            case .envelope(let envelope):
                let script = await Self.render(envelope)
                guard generation == self.generation else { return }
                evaluate(script)
            case .gate(let gate):
                gate.markReached()
                await gate.opened()
                guard generation == self.generation else { return }
            }
            if head == queue.count {
                queue.removeAll(keepingCapacity: true)
                head = 0
            }
        }
        if generation == self.generation { drain = nil }
    }

    @concurrent nonisolated static func render(_ envelope: JSONValue) async -> String {
        PageRouter.receiveScript(envelope)
    }
}

/// A size limit for work the main actor may do on one JSON value.
nonisolated struct PageScriptBudget: Sendable {
    var nodes: Int
    var stringBytes: Int
}

/// A reply object converted off the main actor. The graph is freshly built from Foundation value
/// types (NSNull, NSNumber, String, arrays and dictionaries of them) and handed over once.
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
