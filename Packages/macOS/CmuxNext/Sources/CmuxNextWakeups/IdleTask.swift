/// One idle task, in the run queue, its node's record, or the expiry heap.
@MainActor
final class IdleTask {
    enum State {
        case queued
        case parked
        case done
    }

    let owner: MainTaskOwner
    let site: MainPostSite
    /// Released when the task runs, moves or is dropped.
    var body: (@MainActor (IdleDeadline) -> Void)?
    let expiresNanos: UInt64?
    let record: IdleNodeRecord?
    var state = State.done

    init(owner: MainTaskOwner, site: MainPostSite, body: @escaping @MainActor (IdleDeadline) -> Void, expiresNanos: UInt64?,
         record: IdleNodeRecord?) {
        self.owner = owner
        self.site = site
        self.body = body
        self.expiresNanos = expiresNanos
        self.record = record
    }
}

/// The tasks of one node: its one subscription, its tasks hidden past the delay, and its promoted
/// tasks waiting to run as background work.
@MainActor
final class IdleNodeRecord {
    let id: ObjectIdentifier
    weak var node: VisibilityNode?
    var subscription: VisibilitySubscription?
    /// Its queued and parked tasks.
    var tasks = 0
    var parked: [IdleTask] = []
    var held: [IdleTask] = []
    var wakeRequested = false

    init(id: ObjectIdentifier, node: VisibilityNode) {
        self.id = id
        self.node = node
    }
}

/// A binary min-heap of `maxDelay` expiries, posting order among equal times.
@MainActor
struct IdleExpiryHeap {
    private var items: [(nanos: UInt64, sequence: UInt64, task: IdleTask)] = []

    var count: Int { items.count }
    var top: (nanos: UInt64, task: IdleTask)? {
        guard let first = items.first else { return nil }
        return (nanos: first.nanos, task: first.task)
    }

    mutating func push(_ nanos: UInt64, _ sequence: UInt64, _ task: IdleTask) {
        items.append((nanos: nanos, sequence: sequence, task: task))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(child, parent) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() {
        guard !items.isEmpty else { return }
        items.swapAt(0, items.count - 1)
        items.removeLast()
        siftDown(from: 0)
    }

    mutating func removeAll() {
        items.removeAll()
    }

    mutating func removeAll(where finished: (IdleTask) -> Bool) {
        items.removeAll { finished($0.task) }
        var index = items.count / 2
        while index > 0 {
            index -= 1
            siftDown(from: index)
        }
    }

    private func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
        (items[lhs].nanos, items[lhs].sequence) < (items[rhs].nanos, items[rhs].sequence)
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1, right = left + 1
            var first = parent
            if left < items.count, precedes(left, first) { first = left }
            if right < items.count, precedes(right, first) { first = right }
            guard first != parent else { return }
            items.swapAt(parent, first)
            parent = first
        }
    }
}
