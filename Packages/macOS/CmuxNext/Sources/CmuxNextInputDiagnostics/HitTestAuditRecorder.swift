internal import ObjectiveC

/// The hit-test call stack and the samples, on the main thread. The hooks call ``enter(receiver:resolve:)`` before
/// the original IMP and ``exit()`` after it; the input tap's subscriptions bracket each event with ``eventBegan()``
/// and ``eventEnded()``. In a build without hooks nothing calls it and it holds empty arrays.
final class HitTestAuditRecorder {
    nonisolated static let stackCapacity = 256
    nonisolated static let rowSampleCapacity = 512
    nonisolated static let hitTestSampleCapacity = 4_096
    nonisolated static let eventSampleCapacity = 2_048

    private struct Frame {
        var row: Int
        var receiver: UInt
        var start: UInt64
        var visitsAtEnter: UInt32
        /// `super` on the receiver of the frame below: not a visit, and not recorded.
        var isSuper: Bool
    }

    private struct RowState {
        var type: AnyClass?
        var definesHitTest: Bool
        var ring = HitTestAuditSampleRing(capacity: HitTestAuditRecorder.rowSampleCapacity)
    }

    /// The event in progress: its hit tests so far.
    private struct OpenEvent {
        var nanos: UInt64 = 0
        var views: UInt32 = 0
        var hitTests: UInt32 = 0
    }

    private let now: () -> UInt64
    private(set) var isRecording = false
    private var stack: [Frame] = []
    /// Views visited in the hit test in progress.
    private var visits: UInt32 = 0
    private var rows: [RowState] = []
    private var rowIndex: [UInt: Int] = [:]
    private var hitTests = HitTestAuditSampleRing(capacity: HitTestAuditRecorder.hitTestSampleCapacity)
    private var events = HitTestAuditSampleRing(capacity: HitTestAuditRecorder.eventSampleCapacity)
    private var openEvent = OpenEvent()
    /// Dispatches begun and not yet ended: a nested dispatch joins the outer event.
    private var eventDepth = 0

    init(now: @escaping () -> UInt64) {
        self.now = now
    }

    /// The row of the class at `key`, made on first use.
    func row(key: UInt, type: AnyClass?, definesHitTest: Bool) -> Int {
        if let index = rowIndex[key] { return index }
        rows.append(RowState(type: type, definesHitTest: definesHitTest))
        rowIndex[key] = rows.count - 1
        return rows.count - 1
    }

    /// The row of a view that runs NSView's own `hitTest:`: its class's.
    func inheritedRow(of type: AnyClass?) -> Int {
        row(key: type.map { unsafeBitCast($0, to: UInt.self) } ?? 0, type: type, definesHitTest: false)
    }

    func start() {
        clear()
        stack.reserveCapacity(Self.stackCapacity)
        isRecording = true
    }

    func stop() {
        isRecording = false
        stack.removeAll(keepingCapacity: true)
        visits = 0
        openEvent = OpenEvent()
        eventDepth = 0
    }

    func clear() {
        stack.removeAll(keepingCapacity: true)
        visits = 0
        openEvent = OpenEvent()
        eventDepth = 0
        hitTests.clear()
        events.clear()
        for index in rows.indices { rows[index].ring.clear() }
    }

    func eventBegan() {
        guard isRecording else { return }
        if eventDepth == 0 { openEvent = OpenEvent() }
        eventDepth += 1
    }

    /// Records the open event once its outermost dispatch ends, when it ran at least one hit test.
    func eventEnded() {
        guard eventDepth > 0 else { return }
        eventDepth -= 1
        guard eventDepth == 0, openEvent.hitTests > 0 else { return }
        events.add(nanos: openEvent.nanos, views: openEvent.views, hitTests: openEvent.hitTests)
    }

    /// One `hitTest:` call begins on the view `receiver`; `resolve` gives its row when it is a visit. False when it
    /// is not recorded (not recording, or nested past ``stackCapacity``): then the hook skips ``exit()``.
    func enter(receiver: UInt, resolve: () -> Int) -> Bool {
        guard isRecording, stack.count < Self.stackCapacity else { return false }
        if let top = stack.last, top.receiver == receiver {
            stack.append(Frame(row: top.row, receiver: receiver, start: 0, visitsAtEnter: 0, isSuper: true))
            return true
        }
        let visitsBefore = visits
        visits &+= 1
        let row = resolve()
        stack.append(Frame(row: row, receiver: receiver, start: now(), visitsAtEnter: visitsBefore, isSuper: false))
        return true
    }

    /// The call ``enter(receiver:resolve:)`` began returned.
    func exit() {
        guard let frame = stack.popLast(), !frame.isSuper else { return }
        let end = now()
        let elapsed = end >= frame.start ? end - frame.start : 0
        rows[frame.row].ring.add(nanos: elapsed, views: visits &- frame.visitsAtEnter, hitTests: 1)
        guard stack.isEmpty else { return }
        hitTests.add(nanos: elapsed, views: visits, hitTests: 1)
        if eventDepth > 0 {
            openEvent.nanos &+= elapsed
            openEvent.views &+= visits
            openEvent.hitTests &+= 1
        }
        visits = 0
    }

    func snapshot(available: Bool, installed: Bool, hookedImplementations: Int) -> HitTestAuditSnapshot {
        HitTestAuditSnapshot(
            available: available,
            installed: installed,
            hookedImplementations: hookedImplementations,
            events: events.samples(),
            hitTests: hitTests.samples(),
            rows: rows.map { row in
                HitTestAuditSnapshot.RowSamples(
                    name: row.type.map(HitTestAudit.name(of:)) ?? "?",
                    definesHitTest: row.definesHitTest,
                    samples: row.ring.samples()
                )
            }
        )
    }
}

/// The last `capacity` samples of time, views and hit tests. Storage grows to `capacity` once, then each add
/// overwrites the oldest: adding never allocates after that.
nonisolated struct HitTestAuditSampleRing {
    nonisolated struct Sample {
        var nanos: UInt64
        var views: UInt32
        var hitTests: UInt32
    }

    let capacity: Int
    private(set) var calls: UInt64 = 0
    private var storage: [Sample] = []
    private var next = 0

    init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
    }

    mutating func add(nanos: UInt64, views: UInt32, hitTests: UInt32) {
        let sample = Sample(nanos: nanos, views: views, hitTests: hitTests)
        if storage.count < capacity {
            storage.append(sample)
        } else {
            storage[next] = sample
        }
        next = next + 1 == capacity ? 0 : next + 1
        calls &+= 1
    }

    /// Forgets every sample; the storage stays.
    mutating func clear() {
        calls = 0
        next = 0
        storage.removeAll(keepingCapacity: true)
    }

    /// Columns that share no storage with the ring.
    func samples() -> HitTestAuditSnapshot.Samples {
        HitTestAuditSnapshot.Samples(
            calls: calls,
            nanos: storage.map(\.nanos),
            views: storage.map { UInt64($0.views) },
            hitTests: storage.map { UInt64($0.hitTests) }
        )
    }
}
