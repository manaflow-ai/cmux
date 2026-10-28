import CmuxNextCompat
import CoreFoundation

/// The hook's queues: one FIFO per class, the run-loop source and the observer that arms it, behind the hook's lock.
extension MainExecutorHook {
    /// One queued item and its place in the order all items were queued in.
    struct Entry {
        let sequence: UInt64
        let item: Item
    }

    /// One class's FIFO.
    struct Bucket {
        private var items: [Entry] = []
        private var head = 0

        /// The oldest item's sequence number, nil while empty.
        var headSequence: UInt64? { head < items.count ? items[head].sequence : nil }

        mutating func push(_ entry: Entry) { items.append(entry) }

        mutating func pop() -> Item? {
            guard head < items.count else { return nil }
            let item = items[head].item
            head += 1
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
            return item
        }
    }

    /// The queues and the source, behind one lock: the hook enqueues from any thread.
    struct Queues {
        var buckets = Array(repeating: Bucket(), count: MainExecutorHook.classes.count)
        var stats = Stats()
        /// The sequence number of the next item queued.
        var nextSequence: UInt64 = 0
        /// The run-loop source is signaled and has not started its pass yet.
        var signaled = false
        /// A pass began and the main run loop's before-waiting or exit observers have not run since: the next signal
        /// waits for them (``MainExecutorHook/runLoopObserversRan()``).
        var waitsForObservers = false
        /// The main run loop's source (nil until ``MainExecutorHook/install()``, and in tests).
        var source: CFRunLoopSource?
        /// The observer that arms the next pass after the run loop's observers and the commit.
        var observer: MainRunLoopObserver?

        mutating func push(_ item: Item, at index: Int) {
            buckets[index].push(Entry(sequence: nextSequence, item: item))
            nextSequence += 1
            stats.queued += 1
        }

        /// The oldest item queued before `cutoff` of the highest class that has one; with `inputOnly`, only an
        /// ``MainWorkClass/input`` one.
        mutating func pop(before cutoff: UInt64, inputOnly: Bool) -> Item? {
            let end = inputOnly ? 1 : buckets.count
            for index in 0 ..< end {
                guard let sequence = buckets[index].headSequence, sequence < cutoff, let item = buckets[index].pop() else { continue }
                stats.queued -= 1
                stats.ranByClass[index] += 1
                return item
            }
            return nil
        }

        /// Whether any class still holds an item queued before `cutoff`.
        func holds(before cutoff: UInt64) -> Bool {
            buckets.contains { bucket in bucket.headSequence.map { $0 < cutoff } ?? false }
        }

        /// Signals the source once until its next pass begins (nothing in tests, which have no source).
        mutating func signal() {
            guard !signaled, let source else { return }
            signaled = true
            CFRunLoopSourceSignal(source)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}
