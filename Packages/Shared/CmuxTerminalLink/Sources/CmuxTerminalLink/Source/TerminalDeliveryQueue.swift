import CmuxTerminalRenderCore
import CmuxTerminalStream

/// The phone's drop queue between the link and the renderer
/// (c1-terminal-rpc.md section 6). The link side pushes at once, so link
/// acks keep flowing; the renderer pulls. A READY makes older queued frames
/// moot; grid, title and path events are kept.
actor TerminalDeliveryQueue {
    struct Item: Sendable {
        var event: TerminalSourceEvent
        var queuedAt: Duration
        var cost: Int
        var isFrame: Bool
    }

    private var items: [Item] = []
    private var head = 0
    private(set) var frameBytes = 0
    private var finished = false
    private var waiter: CheckedContinuation<Item?, Never>?

    func push(_ event: TerminalSourceEvent, at now: Duration) {
        guard !finished else { return }
        var cost = 0
        var isFrame = false
        if case .frame(let frame) = event {
            cost = frame.payload.count
            isFrame = true
        }
        let item = Item(event: event, queuedAt: now, cost: cost, isFrame: isFrame)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
            return
        }
        items.append(item)
        frameBytes += cost
    }

    /// Drops every queued frame; returns how many bytes went.
    @discardableResult
    func dropFrames() -> Int {
        let dropped = frameBytes
        items = items[head...].filter { !$0.isFrame }
        head = 0
        frameBytes = 0
        return dropped
    }

    /// Ends the stream after what is queued.
    func finish() {
        finished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    func next() async -> Item? {
        if head < items.count {
            let item = items[head]
            head += 1
            frameBytes -= item.cost
            if head > 64, head * 2 > items.count {
                items.removeFirst(head)
                head = 0
            }
            return item
        }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// The consumer went away.
    func cancel() {
        finished = true
        items.removeAll()
        head = 0
        frameBytes = 0
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
