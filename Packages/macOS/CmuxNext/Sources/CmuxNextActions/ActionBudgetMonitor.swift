import Darwin
public import CmuxNextWakeups

/// The always-on per-action budget: every timed action run's perform-to-commit time, keyed by
/// action id and entrypoint, against the 10 ms budget (plans/cmux-next/zero-latency.md, "Native
/// actions: the budget contract").
///
/// ``SignpostActionRunTiming`` reads the clock when a run starts and again when the Core Animation
/// commit after it ends (the end of `action.commit`), and calls ``record(_:_:start:end:inputAgeMilliseconds:outcome:)``.
/// That is the always-on cost: two monotonic clock reads and one write of a fixed-size slot into a
/// ring preallocated at init, on the main actor (the one writer), with no allocation, no lock, no
/// I/O, no formatting and no string: the slot holds the action's index, interned once when the
/// action was bound (``intern(_:)``, off the action path).
/// `ActionBudgetMonitorBench` measures it in nanoseconds per run.
///
/// Everything else runs after the commit the run is timed to, so it never changes the run:
/// - Each time half the ring has filled, the monitor hands that half to the batch reader
///   (``batches()``) as one array: one copy and one stream yield per ``batchSize`` runs. The App's
///   budget reporter folds the batches into per-action latency histograms off the main actor (the
///   Release report's fields); ``takeUnbatched()`` hands it the runs since the last batch.
/// - An over-budget run, or every run while a reader asked for every run (the Debug latency HUD),
///   goes to the sample readers (``samples(everyRun:)``) at once: the reporter's Debug log line
///   with the watchdog's main-thread sample, the HUD's rows.
///
/// ```swift
/// let budget = ActionBudgetMonitor()
/// let registry = ActionRegistry.standard(runTiming: SignpostActionRunTiming(monitor: budget))
/// for await slow in budget.samples(everyRun: false) { print(slow.id, slow.milliseconds) }
/// ```
public final class ActionBudgetMonitor {
    /// The budget every action run is held to: committed within 10 ms of its start (Lawrence
    /// 2026-10-23: "every single action the user can take ... <10ms").
    public static let defaultBudget: Duration = .milliseconds(10)
    /// Batches kept for a batch reader that fell behind.
    static let batchBuffer = 4

    /// The budget in nanoseconds.
    public let budgetNanos: UInt64
    /// How many runs the ring keeps (a power of two).
    public let capacity: Int
    /// Runs per batch handed to the batch reader: half the ring, so the half being handed over is
    /// never overwritten before it is copied.
    public let batchSize: Int
    /// Runs recorded since launch (the next sample's ``ActionTimingSample/sequence``).
    public private(set) var runCount: UInt64 = 0
    /// Over-budget runs recorded since launch.
    public private(set) var overBudgetCount: UInt64 = 0
    /// Samples a sample reader's stream dropped because the reader fell behind (its buffer was full).
    public private(set) var droppedSampleCount: UInt64 = 0
    /// Runs the batch reader never got: its batch buffer was full, or the ring wrapped first
    /// (the report's `action_runs_dropped`).
    public private(set) var droppedRunCount: UInt64 = 0

    private let ring: ActionSampleRing
    private let batchMask: UInt64
    /// Interned actions by index; index 0 is "none".
    private var names: [ActionID] = [""]
    private var indices: [ActionID: UInt32] = [:]
    /// Where a run is published while it runs (the app's main-thread task board): the watchdog samples a
    /// run past ``budgetNanos`` and records it, with its stack, as an `over_budget` task named by the
    /// action id. Nil publishes nothing.
    public let board: MainTaskBoard?
    /// Each interned action's owner index on ``board``, by monitor index.
    private var owners: [UInt32] = [0]
    /// Runs before this sequence were handed to the batch reader (or had none to go to).
    private var batchedThrough: UInt64 = 0
    private var batchReader: AsyncStream<[ActionTimingSample]>.Continuation?
    private var readers: [UInt64: Reader] = [:]
    private var nextReader: UInt64 = 0
    /// Readers that asked for every run (the HUD); while zero, under-budget runs reach no reader.
    private var everyRunReaders = 0

    private struct Reader {
        let continuation: AsyncStream<ActionTimingSample>.Continuation
        let everyRun: Bool
    }

    /// A monitor with `budget` and a ring of at least `capacity` runs.
    ///
    /// - Parameters:
    ///   - budget: The perform-to-commit budget (``defaultBudget``; tests pass a smaller one).
    ///   - capacity: The runs kept for ``recent(_:)``, rounded up to a power of two, at least 2 (256
    ///     covers the HUD and a socket read after a burst, and makes a batch every 128 runs).
    ///   - board: The main-thread task board runs are published on (``board``), or nil.
    public init(budget: Duration = defaultBudget, capacity: Int = 256, board: MainTaskBoard? = nil) {
        self.board = board
        let (seconds, attoseconds) = budget.components
        budgetNanos = UInt64(clamping: max(seconds, 0)) &* 1_000_000_000 &+ UInt64(clamping: max(attoseconds, 0) / 1_000_000_000)
        ring = ActionSampleRing(capacity: max(capacity, 2))
        self.capacity = ring.capacity
        batchSize = ring.capacity / 2
        batchMask = UInt64(batchSize - 1)
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds: the clock of ``ActionTimingSample/startUptimeNanos``, the
    /// main-thread watchdog's stall records and `NSEvent` timestamps.
    public nonisolated static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Records one run. The always-on part: one write into the ring and two counters; a batch
    /// every ``batchSize`` runs; a sample reader hears the run only when it is over budget or the
    /// reader asked for every run.
    ///
    /// - Parameters:
    ///   - index: The action's interned index (``intern(_:)``).
    ///   - entrypoint: Where the run came from.
    ///   - start: ``now()`` at the run's start.
    ///   - end: ``now()`` at the end of its interval (the commit, for a committed run).
    ///   - inputAgeMilliseconds: The person's input event's age at the start, or -1.
    ///   - outcome: How the interval ended.
    ///   - span: The run's token from ``beginSpan(_:start:)``, ended here at `end`.
    // perf-hot: 0.2us action-budget
    public func record(_ index: UInt32, _ entrypoint: ActionEntrypoint, start: UInt64, end: UInt64,
                       inputAgeMilliseconds: Double, outcome: ActionTimingSample.Outcome,
                       span: MainTaskBoard.SpanToken? = nil) {
        // The span first: an over-budget one gives the watchdog's `over_budget` record (with its
        // stack) before a reader hears the run below.
        // A missed commit (idle time) or a nested loop (the person's dwell) is not the run's work, as
        // for `isOver`: the board ends such a span at its start, so the watchdog records no over-budget task.
        if let span, let board { board.endSpan(span, nowNanos: outcome == .committed ? end : start) }
        let nanos = end > start ? end - start : 0
        ring.write(ActionRunSlot(index: index, entrypoint: entrypoint, outcome: outcome,
                                 inputAgeMilliseconds: Float(inputAgeMilliseconds), startUptimeNanos: start, nanos: nanos),
                   at: runCount)
        runCount &+= 1
        if runCount & batchMask == 0 { handBatch() }
        let over = outcome == .committed && nanos > budgetNanos
        if over { overBudgetCount &+= 1 }
        guard !readers.isEmpty, over || everyRunReaders > 0 else { return }
        deliver(sample(at: runCount &- 1), over: over)
    }

    /// The index `id`'s runs are recorded under, interned on first use. Called when an action is
    /// bound (``ActionRegistry/register(_:)``), never on the action's path.
    ///
    /// - Parameter id: The action.
    /// - Returns: Its index (never 0).
    public func intern(_ id: ActionID) -> UInt32 {
        if let index = indices[id] { return index }
        let index = UInt32(truncatingIfNeeded: names.count)
        names.append(id)
        indices[id] = index
        owners.append(board?.internOwner(id.rawValue) ?? 0)
        return index
    }

    /// Publishes the run of action `index` as the running work on ``board`` from `start`, with the
    /// budget; nil without a board. Atomics only. Pass the token to ``record(_:_:start:end:inputAgeMilliseconds:outcome:span:)``.
    ///
    /// - Parameters:
    ///   - index: The action's interned index.
    ///   - start: ``now()`` at the run's start.
    /// - Returns: The span's token, or nil.
    public func beginSpan(_ index: UInt32, start: UInt64) -> MainTaskBoard.SpanToken? {
        guard let board, Int(index) < owners.count else { return nil }
        return board.beginSpan(.input, owner: owners[Int(index)], budgetNanos: budgetNanos, startNanos: start)
    }

    /// The run of `sequence` as a value (its interned action resolved).
    private func sample(at sequence: UInt64) -> ActionTimingSample {
        let slot = ring.read(at: sequence)
        return ActionTimingSample(sequence: sequence, id: Int(slot.index) < names.count ? names[Int(slot.index)] : "",
                                  entrypoint: slot.entrypoint, startUptimeNanos: slot.startUptimeNanos, nanos: slot.nanos,
                                  inputAgeMilliseconds: Double(slot.inputAgeMilliseconds), outcome: slot.outcome)
    }

    /// The newest `count` runs (at most ``capacity``), newest first.
    public func recent(_ count: Int = 32) -> [ActionTimingSample] {
        let available = Int(min(runCount, UInt64(capacity)))
        let wanted = min(max(count, 0), available)
        return (0..<wanted).map { offset in sample(at: runCount &- 1 &- UInt64(offset)) }
    }

    /// Every run, in batches of ``batchSize`` (oldest first), for the one batch reader (the App's
    /// budget reporter): each batch is handed over when it fills. A newer call replaces the reader.
    /// Runs recorded before the call are not replayed.
    ///
    /// - Returns: The stream of batches.
    public func batches() -> AsyncStream<[ActionTimingSample]> {
        // Four batches wait for a slow reader (a fixed bound: memory never grows); a batch that does
        // not fit is dropped and its runs counted in `droppedRunCount`.
        let (stream, continuation) = AsyncStream<[ActionTimingSample]>.makeStream(bufferingPolicy: .bufferingNewest(Self.batchBuffer))
        batchReader?.finish()
        batchReader = continuation
        batchedThrough = runCount
        return stream
    }

    /// The runs recorded since the last batch (oldest first), now counted as handed over: a report
    /// built between batches takes them so it misses none, and the next batch will not repeat them.
    public func takeUnbatched() -> [ActionTimingSample] {
        let oldestKept = runCount > UInt64(capacity) ? runCount - UInt64(capacity) : 0
        let from = max(batchedThrough, oldestKept)
        // Runs the ring overwrote before anyone took them (no batch reader kept up) are lost: counted.
        if from > batchedThrough, batchReader != nil { droppedRunCount &+= from - batchedThrough }
        let taken = (from..<runCount).map { sample(at: $0) }
        batchedThrough = runCount
        return taken
    }

    /// The runs a reader hears, as they are recorded: only over-budget runs, or every run when
    /// `everyRun` (the HUD). Ends, and the monitor forgets it, when the iterating task is cancelled.
    /// Runs the reader has not taken yet are kept up to its buffer (`bufferingNewest`); a run that
    /// does not fit is counted in ``droppedSampleCount``.
    ///
    /// - Parameter everyRun: Hear every run, not only over-budget ones.
    /// - Returns: The stream.
    public func samples(everyRun: Bool) -> AsyncStream<ActionTimingSample> {
        let id = nextReader
        nextReader &+= 1
        let (stream, continuation) = AsyncStream<ActionTimingSample>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.removeReader(id) }
        }
        readers[id] = Reader(continuation: continuation, everyRun: everyRun)
        if everyRun { everyRunReaders += 1 }
        return stream
    }

    /// Readers still registered (tests: an ended stream is forgotten).
    var readerCount: Int { readers.count }

    /// Hands the half of the ring that just filled to the batch reader (one copy, one yield).
    private func handBatch() {
        guard let batchReader else {
            batchedThrough = runCount
            return
        }
        // Only the runs not already taken (`takeUnbatched`) since the last batch.
        let batch = takeUnbatched()
        guard !batch.isEmpty else { return }
        if case .dropped(let lost) = batchReader.yield(batch) { droppedRunCount &+= UInt64(lost.count) }
    }

    private func deliver(_ sample: ActionTimingSample, over: Bool) {
        for reader in readers.values where over || reader.everyRun {
            if case .dropped = reader.continuation.yield(sample) { droppedSampleCount &+= 1 }
        }
    }

    private func removeReader(_ id: UInt64) {
        guard let reader = readers.removeValue(forKey: id) else { return }
        if reader.everyRun { everyRunReaders -= 1 }
    }
}
