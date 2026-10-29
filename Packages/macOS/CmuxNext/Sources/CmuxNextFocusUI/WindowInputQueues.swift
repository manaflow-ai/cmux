public import AppKit

/// The one held-key queue of each window (principled audit, lagFirstKey): every path that holds a person's key (a
/// creation, a New Tab page) puts it in its window's queue, stamped with its target. The owner frees a window's queue
/// when the window closes (``close(_:)``): its waiting keys drop.
@MainActor
public final class WindowInputQueues {
    private var queues: [Int: WindowInputQueue] = [:]

    public init() {}

    /// Window `number`'s queue, if it has one.
    public func existing(for number: Int) -> WindowInputQueue? { queues[number] }

    /// Window `number`'s queue, made on first use.
    public func queue(for number: Int) -> WindowInputQueue {
        if let queue = queues[number] { return queue }
        let queue = WindowInputQueue()
        queues[number] = queue
        return queue
    }

    /// Window `number` closed: its keys drop and its queue goes.
    public func close(_ number: Int) {
        queues.removeValue(forKey: number)?.close()
    }

    /// The broken parts of every window's invariant (HK1), empty when it holds.
    public var problems: [String] {
        queues.sorted { $0.key < $1.key }.flatMap { number, queue in queue.problems.map { "window \(number): \($0)" } }
    }
}
