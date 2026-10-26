public import CmuxNextCompat

/// The last ``capacity`` memory pressure changes, for `debug.memory`'s `pressure_history`: each
/// change's time since the history started, the level that applies after it (the override when one
/// is set, else the kernel's, as ``MemoryCoordinator/level``), the kernel's raw level, the override
/// and the source (`kernel` from the app's one ``MemoryPressureEvents``, `override` from
/// `debug.hibernation.pressure`, a clear included).
///
/// Event-driven: it records what the pressure source delivers and what the override sets, and
/// nothing else runs. An input that leaves the kernel level and the override as they were is not a
/// change. The kernel source is the analog of Chrome's `SystemMemoryPressureEvaluator`
/// (`components/memory_pressure/system_memory_pressure_evaluator.cc`), which votes each level
/// change; the override is the analog of the DevTools protocol's
/// `Memory.simulatePressureNotification`.
@MainActor
public final class MemoryPressureHistory {
    /// How many changes it keeps (p07-memory.md section 3.G: the last 32).
    public static let capacity = 32

    /// Who changed an input.
    public nonisolated enum Source: String, Sendable, Encodable {
        case kernel
        case override
    }

    /// One change.
    public nonisolated struct Change: Sendable, Equatable {
        /// Milliseconds since the history started (the control socket's start, at launch).
        public let atMilliseconds: Int
        /// The level that applies after the change: ``override`` when set, else ``kernelLevel``.
        public let level: MemoryPressureLevel
        /// The kernel's level after the change.
        public let kernelLevel: MemoryPressureLevel
        /// The debug override after the change; nil when none holds.
        public let override: MemoryPressureLevel?
        public let source: Source

        public init(atMilliseconds: Int, kernelLevel: MemoryPressureLevel, override: MemoryPressureLevel?, source: Source) {
            self.atMilliseconds = atMilliseconds
            level = override ?? kernelLevel
            self.kernelLevel = kernelLevel
            self.override = override
            self.source = source
        }
    }

    /// The history as `debug.memory` copies it.
    public nonisolated struct Snapshot: Sendable, Equatable {
        /// The kept changes, oldest first.
        public var changes: [Change]
        /// When the applied level last changed: a kernel change under an override does not move it.
        public var levelSinceMilliseconds: Int

        public init(changes: [Change], levelSinceMilliseconds: Int) {
            self.changes = changes
            self.levelSinceMilliseconds = levelSinceMilliseconds
        }
    }

    /// The kept changes, oldest first.
    public private(set) var changes: [Change] = []
    /// When the applied level last changed, in milliseconds since the history started.
    public private(set) var levelSinceMilliseconds = 0
    private var kernelLevel: MemoryPressureLevel
    private var override: MemoryPressureLevel?
    private let elapsed: () -> Duration
    /// The source it follows, kept while it follows it (the events cancel their source when released).
    private let pressure: MemoryPressureEvents
    private var observation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// Starts with `pressure`'s current level and no override, and records each kernel change after it.
    ///
    /// - Parameters:
    ///   - pressure: The app's one memory pressure source.
    ///   - elapsed: Time since the history started; the default counts from this init on the continuous clock.
    public init(pressure: MemoryPressureEvents, elapsed: (() -> Duration)? = nil) {
        let start = ContinuousClock.now
        self.elapsed = elapsed ?? { ContinuousClock.now - start }
        self.pressure = pressure
        kernelLevel = pressure.currentLevel
        append(source: .kernel)
        observation = pressure.observe { [weak self] level in self?.kernelLevelDidChange(level) }
    }

    /// The changes and the time the applied level last changed.
    public var snapshot: Snapshot {
        Snapshot(changes: changes, levelSinceMilliseconds: levelSinceMilliseconds)
    }

    /// Records that the debug override is now `override` (nil: cleared), as the coordinator holds it.
    public func overrideDidChange(_ override: MemoryPressureLevel?) {
        guard override != self.override else { return }
        self.override = override
        append(source: .override)
    }

    private func kernelLevelDidChange(_ level: MemoryPressureLevel) {
        guard level != kernelLevel else { return }
        kernelLevel = level
        append(source: .kernel)
    }

    /// Appends the current inputs; drops the oldest change past ``capacity``.
    private func append(source: Source) {
        let change = Change(atMilliseconds: Self.milliseconds(elapsed()), kernelLevel: kernelLevel, override: override, source: source)
        if changes.last?.level != change.level { levelSinceMilliseconds = change.atMilliseconds }
        changes.append(change)
        if changes.count > Self.capacity { changes.removeFirst(changes.count - Self.capacity) }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
