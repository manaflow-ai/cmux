import CmuxNextCompat
import ObjectiveC

/// When a surface's pause last ended, and when its layer next got a frame (`debug.surfaces` `show`).
public nonisolated struct TerminalShowTiming: Sendable, Equatable {
    /// `CLOCK_UPTIME_RAW` nanoseconds of the last unpause (the view's `updateOcclusion`, on main).
    public var unpausedNanos: UInt64
    /// `CLOCK_UPTIME_RAW` nanoseconds of the first `setContents:` on the surface's layer after it; nil
    /// while none came. Core Animation shows that frame at the end of the turn that set it.
    public var firstFrameNanos: UInt64?

    public init(unpausedNanos: UInt64, firstFrameNanos: UInt64?) {
        self.unpausedNanos = unpausedNanos
        self.firstFrameNanos = firstFrameNanos
    }

    /// Milliseconds from the unpause to that frame; nil while it has not come.
    public var unpauseToFrameMilliseconds: Double? {
        firstFrameNanos.map { Double($0 &- unpausedNanos) / 1_000_000 }
    }
}

extension TerminalSurfaceView {
    /// The last unpause and the first frame after it (``TerminalShowRecord``); nil in Release builds.
    var showTiming: TerminalShowTiming? {
        #if DEBUG || CMUX_BENCH_HOOKS
        showRecord.timing
        #else
        nil
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// One surface's show timing, in DEBUG and bench builds only: record only, so a journey can say whether a
/// terminal shown again (its window uncovered) drew within one frame (handoff/v224-gate-triage.md). The main
/// thread writes ``unpaused()`` when the pause ends; the layer's `setContents:` hook (``TypingFrameProbe``, on
/// whatever thread sets the frame) writes ``contentsSet()``. Readers (`debug.surfaces`) read ``timing``.
/// Neither writer waits: two atomic words and one flag. The hook looks a record up (an associated-object read,
/// which takes the runtime's associations lock, as the echo stage's does) only while some record waits for its
/// first frame (the hook's ``TerminalContentsGate/showsWaiting``), so frames at rest cost one relaxed load. A
/// cleared layer (`contents = nil`, a purged held frame) is no frame.
nonisolated final class TerminalShowRecord: Sendable {
    /// The gate the layer's hook reads (the process's, ``GhosttyRuntime/echoStages``): counts waiting records.
    private let gate: TerminalContentsGate
    private let now: @Sendable () -> UInt64
    private let unpausedAt = Atomic<UInt64>(0)
    private let firstFrameAt = Atomic<UInt64>(0)
    private let waitsForFrame = Atomic<Bool>(false)

    /// - Parameters:
    ///   - gate: The contents gate the surface's layer hook was installed with.
    ///   - now: The clock (`CLOCK_UPTIME_RAW` nanoseconds); tests pass their own.
    init(gate: TerminalContentsGate, now: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.gate = gate
        self.now = now
    }

    deinit {
        if waitsForFrame.load(ordering: .relaxed) { gate.showLeft() }
    }

    /// The surface's pause ended now: the next frame its layer gets is the show's frame.
    func unpaused() {
        firstFrameAt.store(0, ordering: .relaxed)
        unpausedAt.store(now(), ordering: .releasing)
        if !waitsForFrame.exchange(true, ordering: .acquiringAndReleasing) { gate.showEntered() }
    }

    /// The surface's layer got a frame now (any thread). The time is read first, so a frame set off main
    /// and preempted after it can never carry a time from after a later unpause.
    func contentsSet() {
        let at = now()
        guard waitsForFrame.exchange(false, ordering: .acquiringAndReleasing) else { return }
        gate.showLeft()
        firstFrameAt.store(at, ordering: .releasing)
    }

    /// The last unpause and the first frame after it; nil before the first unpause.
    var timing: TerminalShowTiming? {
        let unpaused = unpausedAt.load(ordering: .acquiring)
        guard unpaused != 0 else { return nil }
        let frame = firstFrameAt.load(ordering: .acquiring)
        return TerminalShowTiming(unpausedNanos: unpaused, firstFrameNanos: frame >= unpaused && frame != 0 ? frame : nil)
    }

    // MARK: Layer association

    @safe private static var associationKey: UnsafeRawPointer? {
        // SAFETY: built from the identity's bits and only compared by the runtime, never dereferenced; the
        // class's metadata lives for the process, so the address is stable.
        unsafe UnsafeRawPointer(bitPattern: UInt(bitPattern: ObjectIdentifier(TerminalShowRecord.self)))
    }

    /// Ties this record to the layer Ghostty sets the surface's frames on.
    func attach(to layer: AnyObject) {
        guard let key = unsafe Self.associationKey else { return }
        // SAFETY: the key is an address the runtime only compares; the runtime retains this record on `layer`.
        unsafe objc_setAssociatedObject(layer, key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    /// `layer` got a frame: its record's ``contentsSet()``, looked up only while `gate` says some record waits.
    // perf-hot: 0.05us terminal-key
    static func layerGotFrame(_ layer: AnyObject, contents: AnyObject?, gate: TerminalContentsGate) {
        guard contents != nil, gate.showsWaiting, let key = unsafe associationKey else { return }
        // SAFETY: as in `attach(to:)`; the value is an object the layer retains, and the cast checks its type.
        (unsafe objc_getAssociatedObject(layer, key) as? TerminalShowRecord)?.contentsSet()
    }
}
#endif
