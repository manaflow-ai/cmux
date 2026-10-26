import CmuxNextCompat

/// The startup task running now and the launch phase, readable from any thread: the main-thread
/// watchdog reads it from its own thread while the main thread is stuck, so a stall before startup
/// completion names the launch phase and the startup task its sample caught
/// (plans/cmux-next/chrome-parity/p08-startup.md, section E and task 088).
///
/// Chromium does the same with static strings: `base/task/common/task_annotator.cc` keeps a
/// pointer to the running task, whose `Location` points at names compiled into the binary, and its
/// task traces and crash keys read that without a copy or a lock. Here a task's name is its
/// `StaticString`, published as one packed word (address and length), so marking a task never
/// allocates, interns or locks, and the reader turns the word back into text only after the stall.
///
/// The StartupScheduler (p08-startup-010) is the writer: one store when a task starts
/// (``begin(_:)``) and one when it ends (``end()``), all on the main thread; launch code moves the
/// phase forward (``enter(_:)``). A tag is made in `main()` with the watchdog, before anything else
/// runs, and handed to both.
///
/// ```swift
/// let startup = StartupTaskTag()
/// startup.begin("settings.start"); settings.start(); startup.end()
/// let reading = startup.read() // any thread: reading.phase, reading.taskName
/// ```
public final class StartupTaskTag: Sendable {
    /// Where the launch is. Only moves forward.
    public enum Phase: UInt8, Sendable, CaseIterable, CustomStringConvertible {
        /// `main()` up to `NSApp.run` (P1).
        case main = 0
        /// `applicationDidFinishLaunching`'s critical tasks, up to the first window frame (P2).
        case critical = 1
        /// After the first window frame, until startup completes.
        case afterFirstFrame = 2
        /// Startup completed: stalls carry no startup tag from here on.
        case complete = 3

        /// The name stall records and hang reports carry.
        public var description: String {
            switch self {
            case .main: "main"
            case .critical: "critical"
            case .afterFirstFrame: "after_first_frame"
            case .complete: "complete"
            }
        }
    }

    /// One read of the tag: the phase and the packed name of the startup task that was running.
    public struct Reading: Sendable, Equatable {
        /// The packed task word (address in the low 48 bits, byte count in the high 16); 0: no task.
        /// Package-only: a word that did not come from ``StartupTaskTag/read()`` names no valid bytes.
        package let packedTask: UInt64
        /// The phase at the read.
        public let phase: Phase

        /// Rebuilds a reading from the parts of an earlier ``StartupTaskTag/read()`` (the watchdog keeps
        /// them in atomics of its own while the main thread is suspended).
        package init(packedTask: UInt64, phase: Phase) {
            self.packedTask = packedTask
            self.phase = phase
        }

        /// The running startup task's name; nil when none ran. Decodes the name's static bytes (it
        /// allocates a String): call it after the stall, never while the main thread is suspended.
        public var taskName: String? {
            guard let bytes = StartupTaskTag.bytes(of: packedTask) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// Whether the read was taken before startup completed.
        public var isBeforeCompletion: Bool { phase != .complete }
    }

    private let task = Atomic<UInt64>(0)
    private let phaseRaw = Atomic<UInt8>(Phase.main.rawValue)

    /// A tag in ``Phase/main`` with no task running.
    public init() {}

    /// The phase now (any thread).
    public var phase: Phase { Phase(rawValue: phaseRaw.load(ordering: .acquiring)) ?? .complete }

    /// Moves the launch to `phase` (main thread). A phase that is not later than the current one
    /// is ignored, so a late first frame after completion does not reopen startup.
    public func enter(_ phase: Phase) {
        guard phase.rawValue > phaseRaw.load(ordering: .relaxed) else { return }
        phaseRaw.store(phase.rawValue, ordering: .releasing)
    }

    /// A startup task named `name` starts (main thread): one relaxed store. A name the compiler keeps
    /// as a single scalar (one character) has no address and is not published.
    public func begin(_ name: StaticString) {
        task.store(Self.pack(name), ordering: .relaxed)
    }

    /// The running startup task ended (main thread): one relaxed store.
    public func end() {
        task.store(0, ordering: .relaxed)
    }

    /// Runs `work` as the startup task `name` (``begin(_:)``, `work`, ``end()``).
    public func run<Result>(_ name: StaticString, _ work: () throws -> Result) rethrows -> Result {
        begin(name)
        defer { end() }
        return try work()
    }

    /// The phase and the running task (any thread; two atomic loads, no lock, no allocation, so the
    /// watchdog thread may call it while the main thread is suspended).
    public func read() -> Reading {
        Reading(packedTask: task.load(ordering: .relaxed), phase: phase)
    }

    /// The packed word for `name`: its address in the low 48 bits and its byte count in the high 16.
    /// 0 when it has no address, its address does not fit, or it is empty or longer than 65535 bytes.
    static func pack(_ name: StaticString) -> UInt64 {
        guard name.hasPointerRepresentation else { return 0 }
        let address = UInt64(UInt(bitPattern: name.utf8Start))
        let count = UInt64(name.utf8CodeUnitCount)
        guard address != 0, address < 1 << 48, count > 0, count <= 0xFFFF else { return 0 }
        return (count << 48) | address
    }

    /// The static bytes a packed word names; nil for 0.
    static func bytes(of packed: UInt64) -> UnsafeBufferPointer<UInt8>? {
        let count = Int(packed >> 48)
        guard count > 0, let start = UnsafePointer<UInt8>(bitPattern: UInt(packed & ((1 << 48) - 1))) else { return nil }
        return UnsafeBufferPointer(start: start, count: count)
    }
}
