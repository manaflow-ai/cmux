public import CmuxNextCompat

/// The last ``capacity`` memory pressure changes, for `debug.memory`'s `pressure_history`
/// (plans/cmux-next/memory-DESIGN.md section 7): each change's time since the history started, level and
/// source (`kernel` from the app's one ``MemoryPressureEvents``, `override` from
/// `debug.hibernation.pressure`).
///
/// Event-driven: it records what the pressure source delivers and what the override sets, and
/// nothing else runs. A level that repeats the last change's level and source is not a change.
/// The kernel source is the analog of Chrome's `SystemMemoryPressureEvaluator`
/// (`components/memory_pressure/system_memory_pressure_evaluator.cc`), which votes each level
/// change; the override is the analog of the DevTools protocol's
/// `Memory.simulatePressureNotification`.
@MainActor
public final class MemoryPressureHistory {
    /// How many changes it keeps (memory-DESIGN.md: the last 32).
    public static let capacity = 32

    /// Who set a level.
    public nonisolated enum Source: String, Sendable, Encodable {
        case kernel
        case override
        case daemon
    }

    /// One change.
    public nonisolated struct Change: Sendable, Equatable {
        /// Milliseconds since the history started (the control socket's start, at launch).
        public let atMilliseconds: Int
        public let level: MemoryPressureLevel
        public let source: Source

        public init(atMilliseconds: Int, level: MemoryPressureLevel, source: Source) {
            self.atMilliseconds = atMilliseconds
            self.level = level
            self.source = source
        }
    }

    /// The kept changes, oldest first.
    public private(set) var changes: [Change] = []
    private let elapsed: () -> Duration
    /// The source it follows, kept while it follows it (the events cancel their source when released).
    private let pressure: MemoryPressureEvents
    private var observation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// Starts with `pressure`'s current level and records each kernel change after it.
    ///
    /// - Parameters:
    ///   - pressure: The app's one memory pressure source.
    ///   - elapsed: Time since the history started; the default counts from this init on the continuous clock.
    public init(pressure: MemoryPressureEvents, elapsed: (() -> Duration)? = nil) {
        let start = ContinuousClock.now
        self.elapsed = elapsed ?? { ContinuousClock.now - start }
        self.pressure = pressure
        record(pressure.currentLevel, source: .kernel)
        observation = pressure.observe { [weak self] level in self?.record(level, source: .kernel) }
    }

    /// Records `level` from `source` unless the last change has both; drops the oldest change past
    /// ``capacity``.
    public func record(_ level: MemoryPressureLevel, source: Source) {
        if let last = changes.last, last.level == level, last.source == source { return }
        changes.append(Change(atMilliseconds: Self.milliseconds(elapsed()), level: level, source: source))
        if changes.count > Self.capacity { changes.removeFirst(changes.count - Self.capacity) }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
