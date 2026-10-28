import CmuxNextCompat

/// Where the launch is, readable from any thread with atomics only: the ``StartupScheduler``'s phase,
/// whether `main()` still runs, and the startup task running on the main thread. The main-thread
/// watchdog reads it from its own thread while the main thread is suspended, so a stall before startup
/// completes names its launch phase and task (plans/cmux-next/chrome-parity/p08-startup.md, section E
/// and task 088).
///
/// Chromium does the same with static strings: `base/task/common/task_annotator.cc` keeps a pointer to
/// the running task, whose `Location` points at names compiled into the binary, and its traces and
/// crash keys read that without a copy or a lock. Here a task's name is its `StaticString`, kept as
/// one packed word (address and length), so marking a task never allocates, interns or locks; the
/// reader turns the word back into text only after the stall.
///
/// `main()` makes one before anything else, hands it to the watchdog and to the scheduler's
/// ``StartupTaskLog``. The scheduler writes the running task (one exchange at its start, one store at
/// its end) and the phase; `main()` marks its own launch steps (``step(_:)``), which have no
/// scheduler yet; `applicationDidFinishLaunching` ends `main()`'s part (``appFinishedLaunching()``).
///
/// ```swift
/// let tag = StartupTaskTag()
/// tag.step("main.environment"); environment = AppEnvironment.current()
/// let reading = tag.read() // any thread: reading.stallPhase, reading.taskName
/// ```
public final class StartupTaskTag: Sendable {
    /// One read of the tag.
    public struct Reading: Sendable, Equatable {
        /// The packed task word (address in the low 48 bits, byte count in the high 16); 0: no task.
        /// Package-only: a word that did not come from ``StartupTaskTag/read()`` names no valid bytes.
        package let packedTask: UInt64
        /// The scheduler's phase at the read.
        public let phase: StartupTaskLog.Phase
        /// True while `main()` (and AppKit's start under `NSApp.run`) had not reached
        /// `applicationDidFinishLaunching`.
        public let inMain: Bool

        /// Rebuilds a reading from the parts of an earlier ``StartupTaskTag/read()`` (the watchdog keeps
        /// them in atomics of its own while the main thread is suspended).
        package init(packedTask: UInt64, phase: StartupTaskLog.Phase, inMain: Bool) {
            (self.packedTask, self.phase, self.inMain) = (packedTask, phase, inMain)
        }

        /// The running startup task's name; nil when none ran. It allocates a String: call it after
        /// the stall, never while the main thread is suspended.
        public var taskName: String? { StartupTaskTag.name(of: packedTask) }

        /// The launch phase a stall record names (`startup_phase`): `main` (P1, up to
        /// `applicationDidFinishLaunching`), `critical` (P2, to the first window frame),
        /// `after_first_frame`; nil once startup completed or quit began.
        public var stallPhase: String? {
            switch phase {
            case .beforeFirstFrame: inMain ? "main" : "critical"
            case .afterFirstFrame: "after_first_frame"
            case .complete, .quitting: nil
            }
        }
    }

    private let task = Atomic<UInt64>(0)
    private let phaseValue = Atomic<Int>(StartupTaskLog.Phase.beforeFirstFrame.rawValue)
    private let inMain = Atomic<Bool>(true)

    /// A tag in `main()`, before the first frame, with no task running.
    public init() {}

    /// The scheduler's phase now (any thread).
    public var phase: StartupTaskLog.Phase { StartupTaskLog.Phase(rawValue: phaseValue.load(ordering: .acquiring)) ?? .beforeFirstFrame }

    /// The main task running now (any thread), or nil between tasks. It allocates: not for a reader that
    /// runs while the main thread is suspended (``read()`` is).
    public var currentTask: String? { read().taskName }

    /// The phase and the running task: three atomic loads, no lock, no allocation, so the watchdog
    /// thread may call it while the main thread is suspended (any thread).
    public func read() -> Reading {
        Reading(packedTask: task.load(ordering: .acquiring), phase: phase, inMain: inMain.load(ordering: .acquiring))
    }

    /// A launch step of `main()` that no scheduler runs (main thread): one store, until the next
    /// step or ``endStep()``. A one-character name has no address and is not kept.
    public func step(_ name: StaticString) {
        task.store(Self.pack(name), ordering: .releasing)
    }

    /// The running launch step ended (main thread): one store.
    public func endStep() {
        task.store(0, ordering: .releasing)
    }

    /// AppKit called `applicationDidFinishLaunching`: `main()`'s part of the launch is over (main thread).
    public func appFinishedLaunching() {
        inMain.store(false, ordering: .releasing)
    }

    /// The scheduler's phase moved (``StartupTaskLog``).
    func setPhase(_ phase: StartupTaskLog.Phase) {
        phaseValue.store(phase.rawValue, ordering: .releasing)
    }

    /// A scheduler task named `name` starts on main: returns the word it replaced, for ``leave(restoring:)``.
    func enter(_ name: StaticString) -> UInt64 {
        task.exchange(Self.pack(name), ordering: .acquiringAndReleasing)
    }

    /// The scheduler task ended: the outer task or step is current again.
    func leave(restoring outer: UInt64) {
        task.store(outer, ordering: .releasing)
    }

    /// `name`'s address in the low 48 bits and its byte count in the high 16; 0 when it has no address,
    /// the address does not fit, or it is empty or longer than 65535 bytes.
    static func pack(_ name: StaticString) -> UInt64 {
        guard name.hasPointerRepresentation else { return 0 }
        let address = UInt64(UInt(bitPattern: name.utf8Start))
        let count = UInt64(name.utf8CodeUnitCount)
        guard address != 0, address >> 48 == 0, count > 0, count <= 0xFFFF else { return 0 }
        return count << 48 | address
    }

    /// The task name a packed word from ``read()`` names; nil for 0. It allocates a String.
    package static func name(of packed: UInt64) -> String? {
        bytes(of: packed).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The static bytes a packed word names; nil for 0.
    static func bytes(of packed: UInt64) -> UnsafeBufferPointer<UInt8>? {
        let count = Int(packed >> 48)
        guard count > 0, let start = UnsafePointer<UInt8>(bitPattern: UInt(packed & 0x0000_FFFF_FFFF_FFFF)) else { return nil }
        return UnsafeBufferPointer(start: start, count: count)
    }
}
