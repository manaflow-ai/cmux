import CmuxNextCompat

/// The pending-input word the ``MainJobGate`` hook reads with one atomic load
/// (plans/cmux-next/chrome-parity/p04-input.md section 3 (B), tasks 021 and 076).
///
/// It holds the kinds of input the window server has generated and AppKit has not dispatched yet
/// (``SessionInputPending/Kinds``, refreshed once per main run-loop turn), whether an event is in
/// dispatch (set around `CmuxApplication.route`), and the gate's own state: jobs are held, a nested
/// run loop suspends holding, `MainWork` is creating a task. All of it is one word so the hook's
/// pass-through is one load: zero means "forward the job".
///
/// Only the main thread changes the input bits; the gate changes ``Bits/held`` from the thread
/// that holds the first job or releases the last.
///
/// ```swift
/// let state = InputPendingState()
/// state.publish(pending.pendingKinds(uptime: ProcessInfo.processInfo.systemUptime))  // each turn
/// let outer = state.beginDispatch()
/// defer { state.endDispatch(restoring: outer) }
/// ```
public final class InputPendingState: Sendable {
    /// The word's bits.
    public struct Bits: OptionSet, Sendable, Hashable {
        /// The word's bits as a number.
        public let rawValue: UInt32
        /// Bits from their number.
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// A key press is pending.
        public static let key = Bits(rawValue: 1 << 0)
        /// A mouse button press is pending.
        public static let click = Bits(rawValue: 1 << 1)
        /// A scroll begin is pending.
        public static let scrollBegin = Bits(rawValue: 1 << 2)
        /// A drag is pending.
        public static let drag = Bits(rawValue: 1 << 3)
        /// An event is in dispatch on the main thread.
        public static let dispatching = Bits(rawValue: 1 << 4)
        /// The gate holds at least one job: every job that is not exempt queues behind it.
        public static let held = Bits(rawValue: 1 << 5)
        /// A nested run loop (menu tracking, a modal session) runs: nothing is held.
        public static let nestedLoop = Bits(rawValue: 1 << 6)
        /// `MainWork.input` is creating its task on the main thread.
        public static let stampingInput = Bits(rawValue: 1 << 7)
        /// `MainWork.frame` is creating its task on the main thread.
        public static let stampingFrame = Bits(rawValue: 1 << 8)
        /// The gate is stopping or stopped: every job passes.
        public static let bypass = Bits(rawValue: 1 << 9)

        /// The pending kinds (``SessionInputPending/Kinds``'s bits).
        public static let kinds: Bits = [.key, .click, .scrollBegin, .drag]
        /// A person's input: pending or in dispatch.
        public static let input: Bits = [.kinds, .dispatching]
        /// Both stamping bits (``stampingInput`` and ``stampingFrame``).
        public static let stamping: Bits = [.stampingInput, .stampingFrame]
    }

    private let word = Atomic<UInt32>(0)

    /// A word with no bit set.
    public init() {}

    /// The word now. Acquiring: a thread that reads ``Bits/held`` cleared also sees every job the
    /// releasing thread forwarded before it cleared it.
    public var bits: Bits { Bits(rawValue: word.load(ordering: .acquiring)) }

    /// Whether the word is zero: no input, nothing held, nothing stamped (the hook forwards).
    @inline(__always)
    public var isQuiet: Bool { word.load(ordering: .acquiring) == 0 }

    /// The input kinds and the dispatching flag, as the input-turn hop recorder names them.
    public var kinds: SessionInputPending.Kinds {
        SessionInputPending.Kinds(rawValue: UInt8(truncatingIfNeeded: bits.intersection(.kinds).rawValue))
    }

    /// Sets the pending kinds (the main run loop's turn, the end of a dispatch).
    @MainActor
    public func publish(_ kinds: SessionInputPending.Kinds) {
        let new = Bits(rawValue: UInt32(kinds.rawValue)).intersection(.kinds)
        update { $0.subtracting(.kinds).union(new) }
    }

    /// Marks an event in dispatch; returns whether one already was (a nested `sendEvent`).
    @MainActor
    public func beginDispatch() -> Bool {
        let old = update { $0.union(.dispatching) }
        return old.contains(.dispatching)
    }

    /// Ends the dispatch ``beginDispatch()`` began: an outer dispatch stays marked.
    @MainActor
    public func endDispatch(restoring outer: Bool) {
        guard !outer else { return }
        update { $0.subtracting(.dispatching) }
    }

    /// Sets `bits` (any thread); returns the word before.
    @discardableResult
    func insert(_ bits: Bits) -> Bits { update { $0.union(bits) } }

    /// Clears `bits` (any thread); returns the word before.
    @discardableResult
    func remove(_ bits: Bits) -> Bits { update { $0.subtracting(bits) } }

    /// Applies `transform` atomically; returns the word before.
    @discardableResult
    private func update(_ transform: (Bits) -> Bits) -> Bits {
        var old = word.load(ordering: .relaxed)
        var exchanged = false
        while !exchanged {
            (exchanged, old) = word.compareExchange(expected: old, desired: transform(Bits(rawValue: old)).rawValue,
                                                    ordering: .acquiringAndReleasing)
        }
        return Bits(rawValue: old)
    }
}
