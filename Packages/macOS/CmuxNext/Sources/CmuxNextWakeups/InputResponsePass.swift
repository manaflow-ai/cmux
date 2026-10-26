public import CoreFoundation

/// Applies the person's own changes in the input's turn, before the commit
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section 3A, "input-response pass").
///
/// A key or a click whose turn expects a frame opens an input response on the ``MainFrameBudget``
/// (Chrome `third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.h`:
/// `UseCase::kDiscreteInputResponse`, entered only when `is_frame_expected_after_discrete_input`,
/// so the frame after the input runs at input priority). While one is open, this pass runs where
/// Core Animation commits (before waiting, and on exit), ahead of AppKit's display cycle and the
/// commit, and applies, unbudgeted:
/// - every dirty observation whose flush is the person's now, through its
///   ``InputResponseSource`` (VisibleObservation's scheduler, p06-scheduler-025): one that an automation change
///   dirtied first and the person's change then hit is the person's; one that only automation
///   dirtied waits for its own class;
/// - then every batch item the person caused (``enqueue(owner:_:)``), in order, those the
///   applies queued included.
///
/// The observer is on the run loop only while a response is open, and after it closes only until
/// the items accepted while it was open have run: a turn outside a response pays nothing.
///
/// ```swift
/// let pass = InputResponsePass(budget: mainWork.budget)
/// pass.addSource(causes)
/// // A person-caused sidebar patch (FrameBatchQueue): false outside a response.
/// if !pass.enqueue(owner: owner, patch) { runAsUserBlocking(patch) }
/// ```
@MainActor
public final class InputResponsePass {
    /// The observer's order: after the app's default-order observers (0), before AppKit's display
    /// cycle and Core Animation's commit (2,000,000). Not `CommitBoundary.order - 1`: that equals
    /// the commit's order, and CFRunLoop runs an observer added later at an equal order after the
    /// one Core Animation installed at launch.
    public static let order: CFIndex = 1_000_000

    /// What the pass did (tests and benches read it).
    public struct Stats: Sendable, Equatable {
        /// Passes that ran.
        public var passes = 0
        /// Observations applied in a pass.
        public var observations = 0
        /// Batch items run in a pass.
        public var items = 0
        /// Times the observer was put on the run loop.
        public var installs = 0
    }

    public private(set) var stats = Stats()
    private let budget: MainFrameBudget
    private let runLoop: any InputResponseRunLoop
    private let itemOwner: MainTaskOwner
    private let observationOwner: MainTaskOwner
    private var observer: (any InputResponseObservation)?
    private var sources: [WeakSource] = []
    private var items: [Item] = []

    /// - Parameters:
    ///   - budget: The budget whose input response the pass follows (it tells the pass when one
    ///     opens and closes); one pass per budget.
    ///   - runLoop: Where the observer goes (the app: the main run loop; tests: a fake).
    public init(budget: MainFrameBudget, runLoop: any InputResponseRunLoop = MainRunLoopBeforeCommit()) {
        self.budget = budget
        self.runLoop = runLoop
        itemOwner = budget.board.owner("InputResponsePass.items")
        observationOwner = budget.board.owner("InputResponsePass.observations")
        budget.inputResponsePass = self
        updateObserver()
    }

    /// Whether the observer is on the run loop now.
    public var isInstalled: Bool { observer != nil }

    /// Adds a source of person-caused observations, held weakly; each pass asks it to apply them.
    public func addSource(_ source: any InputResponseSource) {
        sources.removeAll { $0.value == nil || $0.value === source }
        sources.append(WeakSource(value: source))
    }

    /// Queues a person-caused batch item for this turn's pass. Returns false and queues nothing
    /// when no input response is open: the caller runs it as user-blocking work.
    @discardableResult
    public func enqueue(owner: MainTaskOwner? = nil, _ work: @escaping @MainActor () -> Void) -> Bool {
        guard budget.isInputResponseOpen else { return false }
        items.append(Item(owner: owner ?? itemOwner, work: work))
        updateObserver()
        return true
    }

    /// The budget's input response opened or closed.
    func inputResponseChanged() {
        updateObserver()
    }

    private func updateObserver() {
        let wanted = budget.isInputResponseOpen || !items.isEmpty
        if wanted, observer == nil {
            stats.installs += 1
            observer = runLoop.observeBeforeCommit(order: Self.order) { [weak self] in self?.drain() }
        } else if !wanted, let observer {
            observer.invalidate()
            self.observer = nil
        }
    }

    /// One pass: the sources' person-caused observations, then the person's batch items.
    private func drain() {
        stats.passes += 1
        if budget.isInputResponseOpen {
            for source in sources {
                guard let source = source.value else { continue }
                // Published on the board, so a stall in an apply names the pass.
                let applied = budget.run(.input, owner: observationOwner) { source.applyPersonCaused() }
                stats.observations += applied
            }
            sources.removeAll { $0.value == nil }
        }
        while !items.isEmpty {
            let batch = items
            items.removeAll(keepingCapacity: true)
            for item in batch {
                stats.items += 1
                budget.run(.input, owner: item.owner) { item.work() }
            }
        }
        updateObserver()
    }

    private struct Item {
        var owner: MainTaskOwner
        var work: @MainActor () -> Void
    }

    private struct WeakSource {
        weak var value: (any InputResponseSource)?
    }
}

/// What holds the dirty observations an ``InputResponsePass`` drains: VisibleObservation's
/// scheduler (p06-scheduler-025), which knows each one's recorded cause and the
/// `personCauseEpoch`.
@MainActor
public protocol InputResponseSource: AnyObject {
    /// Applies now, unbudgeted, every dirty observation whose flush class is person (its recorded
    /// cause is person, or the person-cause epoch moved since it became dirty), each once and in
    /// the order they became dirty; leaves the rest to their classes.
    ///
    /// - Returns: How many it applied.
    func applyPersonCaused() -> Int
}
