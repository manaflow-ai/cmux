// Public: the inlined hook read in `blockingCall` names the Compat `Atomic<UInt64>`, whose `AtomicValue`
// conformance comes from swift-atomics.
public import Atomics

/// Where the process's checked blocking calls write their trace intervals while a trace records them: two
/// calls, one when a ``blockingCall(_:fileID:line:_:)`` opens and one when it returns. The trace runtime
/// (CmuxNextTrace, which this module sits below) makes one and hands it to ``BlockingTraceHook``.
///
/// ```swift
/// let sink = BlockingTraceSink(began: { kind, fileID, line in ring.begin(...) }, ended: { kind in ring.end(...) })
/// ```
public final class BlockingTraceSink: Sendable {
    /// Writes the begin of one call's interval; returns whether it was written, so a written begin always
    /// gets its end even when the trace stops while the call runs.
    @usableFromInline let began: @Sendable (BlockingKind, StaticString, UInt) -> Bool
    /// Writes the end of a written begin.
    @usableFromInline let ended: @Sendable (BlockingKind) -> Void
    /// Whether ``BlockingTraceHook`` has taken its one reference.
    let pinned = Atomic<Bool>(false)

    /// - Parameters:
    ///   - began: Writes a call's begin from its kind and site (`#fileID`, `#line`); returns whether it did.
    ///   - ended: Writes the end of a begin that `began` wrote.
    public init(began: @escaping @Sendable (_ kind: BlockingKind, _ fileID: StaticString, _ line: UInt) -> Bool,
                ended: @escaping @Sendable (_ kind: BlockingKind) -> Void) {
        self.began = began
        self.ended = ended
    }

    /// Runs `body` inside one interval of this sink.
    @inlinable
    func interval<Result, Failure: Error>(
        _ kind: BlockingKind, fileID: StaticString, line: UInt, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let written = began(kind, fileID, line)
        defer { if written { ended(kind) } }
        return try body()
    }
}

/// The trace hook of ``blockingCall(_:fileID:line:_:)``, in every build, Release included: one word that holds
/// the sink recording the process's blocking calls, 0 while none does. Off, a blocking call pays one acquiring
/// load and one branch for it (p02-threads task 124).
///
/// Chrome writes the same interval from `ScopedBlockingCall` (base/threading/scoped_blocking_call.cc,
/// `TRACE_EVENT_BEGIN("base", "ScopedBlockingCall", ...)` with the call's location) through its one
/// process-wide `TraceLog`. Here the trace runtime lives in CmuxNextTrace, above this module, so the call reaches
/// it through this hook: the runtime that routes the process's blocking calls (`TraceRuntime.shared`) stores its
/// sink when its `task` category turns on and clears it when the category turns off.
///
/// One hook per process (``process``): a blocking call runs in any module, on any thread, inside any lock and
/// before the composition root exists, so it has no instance to take its hook through, the reason
/// ``BlockingViolationTable`` and `TraceRuntime.shared` are process-wide too.
public final class BlockingTraceHook: Sendable {
    /// The process's hook.
    // singleton-allow: blockingCall is a free function every module's seams call with no injection path; Chrome's ScopedBlockingCall writes to the process-wide TraceLog.
    // lint:allow singleton: the blocking-call trace hook exception in plans/cmux-next/arch-ratchet.json (2026-10-26).
    @usableFromInline static let process = BlockingTraceHook()

    /// The address of the sink that records blocking calls now (an `Unmanaged` reference the hook retained
    /// once and never releases), 0 while none does.
    @usableFromInline let recording = Atomic<UInt64>(0)

    init() {}

    /// The sink that records the process's blocking calls now; nil while none does. One acquiring load: it pairs
    /// with ``update(_:recording:)``'s store, so the sink's fields are initialized before a caller reads them.
    @inlinable @inline(__always)
    static var recordingSink: BlockingTraceSink? {
        let address = process.recording.load(ordering: .acquiring)
        // SAFETY: a nonzero address is one update(_:recording:) stored: a sink it retained once and never releases,
        // so the reference is live for the process's life and taking it unretained is balanced.
        guard address != 0, let pointer = unsafe UnsafeRawPointer(bitPattern: UInt(address)) else { return nil }
        return unsafe Unmanaged<BlockingTraceSink>.fromOpaque(pointer).takeUnretainedValue()
    }

    /// Whether some sink records the process's blocking calls now.
    public static var isRecording: Bool { recordingSink != nil }

    /// Makes `sink` record the process's blocking calls (`recording` true) or stop recording them (false). A
    /// stop clears the hook only while `sink` is the one recording, so a runtime that stops never silences
    /// another one's recording. The hook takes one reference to `sink` the first time, and keeps it: a call on
    /// another thread may still hold the address it loaded.
    ///
    /// - Parameters:
    ///   - sink: The sink of a trace runtime.
    ///   - recording: Whether its blocking-call category records now.
    public static func update(_ sink: BlockingTraceSink, recording: Bool) {
        // SAFETY: the one retain each sink gets (`pinned` flips once), never released, keeps every address this
        // stores live for recordingSink; the address is stored as an integer and read back only there.
        if !sink.pinned.exchange(true, ordering: .sequentiallyConsistent) {
            _ = unsafe Unmanaged.passRetained(sink)
        }
        let address = UInt64(UInt(bitPattern: ObjectIdentifier(sink))) // the sink's address, from its identity
        if recording {
            process.recording.store(address, ordering: .sequentiallyConsistent)
        } else {
            process.recording.compareExchange(expected: address, desired: 0, ordering: .sequentiallyConsistent)
        }
    }
}

extension BlockingKind {
    /// The kind's number in a trace record (the low byte of a `task.blocking_call` begin's arg0,
    /// plans/cmux-next/trace.md). Fixed: a kind keeps its number, a new kind takes the next one.
    public var traceCode: UInt8 {
        switch self {
        case .fileIO: 1
        case .socketRead: 2
        case .socketWrite: 3
        case .syncWait: 4
        case .ipcReply: 5
        case .processWait: 6
        case .processSpawn: 7
        case .lockWait: 8
        case .systemCall: 9
        case .sleep: 10
        case .wrongLane: 11
        case .cpuIntensive: 12
        case .fsMetadata: 13
        case .sqlite: 14
        case .processReap: 15
        case .systemQuery: 16
        case .priorityInversion: 17
        case .ffi: 18
        case .xpcReply: 19
        }
    }
}
