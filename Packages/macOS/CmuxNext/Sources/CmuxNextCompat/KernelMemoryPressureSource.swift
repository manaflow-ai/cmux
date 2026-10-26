import Darwin
import Dispatch

/// The kernel's memory pressure: one dispatch source on the main queue, so each change reaches
/// ``MemoryPressureEvents`` on the main actor at once (event-driven: no timer, nothing polls).
///
/// It works as Chrome's `SystemMemoryPressureEvaluator` does
/// (`components/memory_pressure/system_memory_pressure_evaluator_mac.cc`): an event only says that
/// the level may have changed. The handler ignores the event's data, which is the OR of every event
/// libdispatch coalesced (a WARN then NORMAL pair reads as warning), and reads
/// `kern.memorystatus_vm_pressure_level` instead. It reads the level once at start too, so
/// ``currentLevel`` is right before the first event, and it delivers a level only when it differs
/// from the last one.
///
/// Make one at the composition root and hand it to the app's one ``MemoryPressureEvents``. The
/// dispatch source exists only from ``start(delivering:)`` on, and it is active from the moment it
/// exists, so the instance is safe to release in every state: never started, cancelled before start,
/// or started and cancelled (libdispatch traps when an inactive source is released).
public final class KernelMemoryPressureSource: MemoryPressureSource {
    private struct State {
        var source: (any DispatchSourceMemoryPressure)?
        var deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)?
        var level = MemoryPressureLevel.normal
        var isCancelled = false
    }

    // Lock carve-out: start, cancel and currentLevel run on any thread (MemoryPressureEvents' init
    // and nonisolated deinit, a reader of the level); the critical sections copy or set a few fields
    // and make, activate or cancel the source. None waits, reads the kernel or delivers inline.
    private let state = Mutex(State())
    private let readKernelLevel: @Sendable () -> Int32?

    /// Makes an idle source that reads `kern.memorystatus_vm_pressure_level`; the dispatch source
    /// is made and activated in ``start(delivering:)``.
    public convenience init() {
        self.init(readKernelLevel: { KernelMemoryPressureSource.readSysctlLevel() })
    }

    /// Makes an idle source that reads the kernel's level through `readKernelLevel`.
    ///
    /// - Parameter readKernelLevel: The raw `kern.memorystatus_vm_pressure_level` (1 normal,
    ///   2 warning, 4 critical), or nil when it cannot be read; a test passes a value it sets.
    package init(readKernelLevel: @escaping @Sendable () -> Int32?) {
        self.readKernelLevel = readKernelLevel
    }

    /// The level the source last read: the kernel's level at ``start(delivering:)`` until a change;
    /// normal before start and while the kernel's level has never been readable. Any thread; set
    /// before the level is delivered, so a subscriber reads the level it is handed.
    public var currentLevel: MemoryPressureLevel {
        state.withLock { $0.level }
    }

    /// Reads the kernel's level, then makes the dispatch source, sets its event handler and
    /// activates it. Does nothing after ``cancel()`` or a second time. The level read here is not
    /// delivered (no subscriber exists yet); it becomes ``currentLevel``.
    ///
    /// - Parameter deliver: Main-actor work for each new level.
    public func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        guard state.withLock({ !$0.isCancelled && $0.source == nil }) else { return }
        let initial = readLevel()
        state.withLock { state in
            guard !state.isCancelled, state.source == nil else { return }
            if let initial { state.level = initial }
            state.deliver = deliver
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                // main-proof: the source delivers on the main queue (queue: .main).
                MainActor.assumeIsolated { self.kernelLevelMayHaveChanged() }
            }
            source.activate()
            state.source = source
        }
    }

    /// Cancels the dispatch source: its event handler runs no more, nothing more is delivered, and
    /// a later ``start(delivering:)`` does nothing.
    public func cancel() {
        state.withLock { state in
            state.isCancelled = true
            state.source?.cancel()
        }
    }

    /// The dispatch source's event handler; a test calls it as the event. Reads the kernel's level
    /// and delivers it when it differs from the last one; an unreadable level keeps the last one.
    @MainActor package func kernelLevelMayHaveChanged() {
        guard let level = readLevel() else { return }
        let deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)? = state.withLock { state in
            guard !state.isCancelled, state.level != level else { return nil }
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
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : nil
    }
}
