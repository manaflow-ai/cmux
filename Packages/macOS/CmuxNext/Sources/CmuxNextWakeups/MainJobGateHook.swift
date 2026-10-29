import CmuxNextCompat
import CoreFoundation
import Darwin

/// The runtime's main-executor enqueue (`swift_task_enqueueMainExecutorImpl`), as the hook gets it.
typealias MainEnqueueOriginal = @convention(thin) (UnownedJob) -> Void
/// `swift_task_enqueueMainExecutor_hook`'s type (swift/include/swift/Runtime/Concurrency.h): Swift's
/// calling convention, the job and the original enqueue.
typealias MainEnqueueHook = @convention(thin) (UnownedJob, MainEnqueueOriginal) -> Void

/// Installs a ``MainJobGate`` as the Swift runtime's `swift_task_enqueueMainExecutor_hook`:
/// every main-actor job of the process goes through the gate first.
///
/// The hook is found with `dlsym` at runtime, as `AlternateSignalStacks` finds the pthread
/// hooks; a runtime without it throws ``HookError/notFound`` and the app runs without the gate.
/// One gate at a time, and only while nothing else hooks the main executor: the hook is a process
/// global. Uninstall releases what the gate held and removes the hook. Off (feature `mainJobGate`,
/// setting `debug.mainJobGate`), the hook is never installed.
///
/// ```swift
/// let gate = MainJobGate(state: InputPendingState())
/// let hook = try MainJobGateHook()
/// try hook.install(gate)
/// hook.uninstall()
/// ```
@MainActor
public final class MainJobGateHook {
    /// Why the hook cannot be installed.
    public enum HookError: Error, Equatable {
        /// The Swift runtime does not export `swift_task_enqueueMainExecutor_hook`.
        case notFound
        /// Another gate is installed.
        case alreadyInstalled
        /// Something else already hooks the main executor: the gate does not chain behind it.
        case otherHookInstalled
    }

    nonisolated static let symbol = "swift_task_enqueueMainExecutor_hook"

    private let slot: UnsafeMutablePointer<MainEnqueueHook?>
    private var installed: MainJobGate?

    /// Finds the runtime's hook.
    public init() throws(HookError) {
        // SAFETY: dlopen(nil) is the main program's handle, which stays open for the process; dlsym returns
        // the address of the runtime's exported hook variable, a pointer-sized, pointer-aligned global.
        guard let address = unsafe dlsym(dlopen(nil, RTLD_NOW), Self.symbol) else { throw .notFound }
        // SAFETY: as above; the variable's type is MainEnqueueHook? (a nullable function pointer).
        slot = unsafe address.assumingMemoryBound(to: MainEnqueueHook?.self)
    }

    /// Whether this hook has a gate installed.
    public var isInstalled: Bool { installed != nil }

    /// Routes every main-actor job through `gate`.
    public func install(_ gate: MainJobGate) throws(HookError) {
        // SAFETY: `slot` is the runtime's hook variable (init); the runtime reads it with plain
        // pointer-sized loads, so an aligned pointer-sized load or store is seen whole.
        guard unsafe slot.pointee == nil else { throw installed == nil ? .otherHookInstalled : .alreadyInstalled }
        guard installed == nil, MainJobGateRoute.claim(gate) else { throw .alreadyInstalled }
        installed = gate
        gate.start()
        // SAFETY: as above.
        unsafe slot.pointee = MainJobGateRoute.hook()
    }

    /// Releases every held job in order, then removes the hook. A job enqueued meanwhile passes
    /// behind the released ones.
    public func uninstall() {
        guard let gate = installed else { return }
        gate.stop()
        // SAFETY: as in install.
        unsafe slot.pointee = nil
        installed = nil
        MainJobGateRoute.unclaim()
    }
}

extension MainJobGate {
    /// A gate that forwards to the runtime's original enqueue and wakes the main run loop when it
    /// holds a job.
    public convenience init(state: InputPendingState) {
        self.init(state: state, forward: Self.runtimeForward, wakeMain: { CFRunLoopWakeUp(CFRunLoopGetMain()) })
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// ``init(state:)`` that also records each job enqueued during input into `recorder` (task 022).
    public convenience init(state: InputPendingState, recorder: MainJobGateDiagnostics?) {
        self.init(state: state, recorder: recorder, forward: Self.runtimeForward, wakeMain: { CFRunLoopWakeUp(CFRunLoopGetMain()) })
    }
    #endif

    /// Hands a job the hook took to the runtime's own enqueue.
    static let runtimeForward: @Sendable (Entry) -> Void = { entry in
        // SAFETY: `original` and `job` are the bit patterns MainJobGateRoute.enqueue took from the runtime's
        // MainEnqueueOriginal and UnownedJob (both one pointer); each held job is forwarded exactly once.
        let original = unsafe unsafeBitCast(entry.original, to: MainEnqueueOriginal.self)
        // SAFETY: as above.
        original(unsafe unsafeBitCast(entry.job, to: UnownedJob.self))
    }
}

/// The installed gate, for the hook, which is a thin function with no context.
nonisolated enum MainJobGateRoute {
    /// The installed gate's retained address; 0 when none. An uninstalled gate stays retained: a
    /// thread may still be inside its hook.
    private static let installed = GateWord()

    /// The hook function: a closure made here, outside any actor, with no context. It names
    /// `MainJobGateRoute` explicitly: a bare `enqueue` would capture `self` (the metatype), and a
    /// thin function cannot carry a capture (as `GlobalJobCensus`'s hook).
    static func hook() -> MainEnqueueHook {
        { job, original in MainJobGateRoute.enqueue(job, original) }
    }

    static func claim(_ gate: MainJobGate) -> Bool {
        let retained = Unmanaged.passRetained(gate)
        // SAFETY: the retain is kept for the process (see `installed`), so the address stays valid.
        let address = UInt(bitPattern: unsafe retained.toOpaque())
        let claimed = installed.value.compareExchange(expected: 0, desired: address, ordering: .acquiringAndReleasing).exchanged
        // SAFETY: the claim failed, so no hook read this retain: give it back.
        if !claimed { unsafe retained.release() }
        return claimed
    }

    static func unclaim() {
        installed.value.store(0, ordering: .releasing)
    }

    /// The hook: one acquiring load of the gate's word when it is quiet, then the original enqueue.
    // perf-hot: 100ns main-turn (every main-actor job's enqueue: the hook's pass-through)
    static func enqueue(_ job: UnownedJob, _ original: MainEnqueueOriginal) {
        let address = installed.value.load(ordering: .acquiring)
        // SAFETY: a non-zero address is a gate retained for the process (claim).
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return original(job) }
        // SAFETY: as above; the guaranteed reference needs no retain while the call runs.
        unsafe Unmanaged<MainJobGate>.fromOpaque(pointer)._withUnsafeGuaranteedRef { gate in
            guard !gate.state.isQuiet else { return original(job) }
            // SAFETY: both are one pointer; runtimeForward turns them back.
            let entry = MainJobGate.Entry(job: unsafe unsafeBitCast(job, to: UInt.self),
                                          original: unsafe unsafeBitCast(original, to: UInt.self),
                                          priority: job.priority.rawValue)
            gate.enqueue(entry, bits: gate.state.bits, onMain: pthread_main_np() != 0)
        }
    }
}
