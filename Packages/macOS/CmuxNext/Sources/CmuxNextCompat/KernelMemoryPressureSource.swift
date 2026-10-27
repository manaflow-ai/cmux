import Darwin
import Dispatch

/// The kernel's memory pressure: one dispatch source on the main queue, so each change reaches
/// ``MemoryPressureEvents`` on the main actor at once (event-driven: no timer, nothing polls).
///
/// It works as Chrome's `SystemMemoryPressureEvaluator` does
/// (`components/memory_pressure/system_memory_pressure_evaluator_mac.cc`): an event only says that
/// the level may have changed. The handler ignores the event's data, which is the OR of every event
/// libdispatch coalesced (a WARN then NORMAL pair reads as warning), and reads
/// `kern.memorystatus_vm_pressure_level` instead. At start it subscribes first and then reads the
/// level, so ``currentLevel`` is right before the first event and a change between the two still
/// comes as an event. It delivers a level only when it differs from the last one.
///
/// Make one at the composition root and hand it to the app's one ``MemoryPressureEvents``. The
/// dispatch source exists only from ``start(delivering:)`` on, and it is active from the moment it
/// exists, so the instance is safe to release in every state: never started, cancelled before start,
/// or started and cancelled (libdispatch traps when an inactive source is released).
public final class KernelMemoryPressureSource: MemoryPressureSource {
    /// Subscribes `handler` to the kernel's memory pressure events, active when it returns, and
    /// returns the subscription. The handler runs on the main actor with the event's data (the
    /// `DISPATCH_MEMORYPRESSURE_*` bits of every event libdispatch coalesced). The app's is a
    /// dispatch source on the main queue; a test passes one it fires.
    package typealias Subscribe = @Sendable (_ handler: @escaping @MainActor @Sendable (_ eventData: UInt) -> Void)
        -> any MemoryPressureSubscription

    private struct State {
        var subscription: (any MemoryPressureSubscription)?
        var deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)?
        var level = MemoryPressureLevel.normal
        /// An event read the kernel after the subscription; the read at start may be older.
        var hasEventLevel = false
        var isCancelled = false
    }

    // Lock carve-out: start, cancel and currentLevel run on any thread (MemoryPressureEvents' init
    // and nonisolated deinit, a reader of the level); the critical sections copy or set a few fields
    // and make or cancel the subscription. None waits, reads the kernel or delivers inline.
    private let state = Mutex(State())
    private let readKernelLevel: @Sendable () -> Int32?
    private let subscribe: Subscribe

    /// Makes an idle source that reads `kern.memorystatus_vm_pressure_level` on the events of a
    /// dispatch source; the dispatch source is made and activated in ``start(delivering:)``.
    public convenience init() {
        self.init(
            readKernelLevel: { KernelMemoryPressureSource.readSysctlLevel() },
            subscribe: { KernelMemoryPressureSource.subscribeToDispatchSource($0) }
        )
    }

    /// Makes an idle source that reads the kernel's level through `readKernelLevel` on each event
    /// that `subscribe` delivers.
    ///
    /// - Parameters:
    ///   - readKernelLevel: The raw `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning,
    ///     4 critical), or nil when it cannot be read; a test passes a value it sets.
    ///   - subscribe: Subscribes the event handler; called once, in ``start(delivering:)``.
    package init(readKernelLevel: @escaping @Sendable () -> Int32?, subscribe: @escaping Subscribe) {
        self.readKernelLevel = readKernelLevel
        self.subscribe = subscribe
    }

    /// The level the source last read: the kernel's level at ``start(delivering:)`` until a change;
    /// normal before start and while the kernel's level has never been readable. Any thread; set
    /// before the level is delivered, so a subscriber reads the level it is handed.
    public var currentLevel: MemoryPressureLevel {
        state.withLock { $0.level }
    }

    /// Subscribes to the kernel's events, then reads the kernel's level (Chrome's evaluator also
    /// subscribes before it reads its initial vote). Does nothing after ``cancel()`` or a second
    /// time. The level read here is not delivered (no subscriber exists yet); it becomes
    /// ``currentLevel`` unless an event already read a newer one.
    ///
    /// - Parameter deliver: Main-actor work for each new level.
    public func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        let subscribed: Bool = state.withLock { state in
            guard !state.isCancelled, state.subscription == nil else { return false }
            state.deliver = deliver
            // The event's data is ignored: the handler reads the kernel's level.
            state.subscription = subscribe { [weak self] _ in self?.kernelLevelMayHaveChanged() }
            return true
        }
        guard subscribed, let initial = readLevel() else { return }
        state.withLock { state in
            guard !state.isCancelled, !state.hasEventLevel else { return }
            state.level = initial
        }
    }

    /// Cancels the subscription: its event handler runs no more, nothing more is delivered, and
    /// a later ``start(delivering:)`` does nothing.
    public func cancel() {
        state.withLock { state in
            state.isCancelled = true
            state.subscription?.cancel()
        }
    }

    /// The event handler: reads the kernel's level and delivers it when it differs from the last
    /// one; an unreadable level keeps the last one.
    @MainActor private func kernelLevelMayHaveChanged() {
        guard let level = readLevel() else { return }
        let deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)? = state.withLock { state in
            guard !state.isCancelled else { return nil }
            state.hasEventLevel = true
            guard state.level != level else { return nil }
            state.level = level
            return state.deliver
        }
        deliver?(level)
    }

    /// The kernel's level as a ``MemoryPressureLevel``. The raw values are libdispatch's
    /// `DISPATCH_MEMORYPRESSURE_NORMAL`, `_WARN` and `_CRITICAL`; nil when the read fails or gives
    /// another value (Chrome maps another value to normal; cmux keeps the last level instead).
    private func readLevel() -> MemoryPressureLevel? {
        switch readKernelLevel() {
        case 1?: .normal
        case 2?: .warning
        case 4?: .critical
        default: nil
        }
    }

    /// `kern.memorystatus_vm_pressure_level`, or nil when sysctl fails.
    private static func readSysctlLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // SAFETY: sysctlbyname reads the NUL-terminated name made for the call and writes at most `size` bytes (one
        // Int32) into `level` and the size it wrote into `size`; both are locals.
        return unsafe sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : nil
    }

    /// A memory pressure dispatch source on the main queue, active when it returns.
    private static func subscribeToDispatchSource(
        _ handler: @escaping @MainActor @Sendable (_ eventData: UInt) -> Void
    ) -> any MemoryPressureSubscription {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let eventData = source?.data.rawValue else { return }
            // main-proof: the source delivers on the main queue (queue: .main).
            MainActor.assumeIsolated { handler(eventData) }
        }
        source.activate()
        return DispatchMemoryPressureSubscription(source: source)
    }
}

/// One subscription to the kernel's memory pressure events (``KernelMemoryPressureSource/Subscribe``).
package protocol MemoryPressureSubscription {
    /// Stops the events: the handler runs no more. Any thread.
    func cancel()
}

/// The app's subscription: an active memory pressure dispatch source.
private struct DispatchMemoryPressureSubscription: MemoryPressureSubscription {
    let source: any DispatchSourceMemoryPressure

    func cancel() {
        source.cancel()
    }
}
