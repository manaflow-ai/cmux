/// The memory consumer of one pool of spares: pages or windows made at an idle moment before anyone
/// asks, so the next open adopts one instead of building it (the new tab spare, the page host spare,
/// Chromium's spare windows).
///
/// Chrome's rule for its spare renderer (`content/browser/renderer_host/spare_render_process_host_manager_impl.cc`,
/// p07-memory.md section 1.13): no new spare under memory pressure, and none is warmed again until the
/// pressure ends. Chrome keeps an existing spare (`kKillSpareRenderOnMemoryPressure` is off by
/// default); each cmux pool says at which level its untaken spares close (``Closing``). A spare holds
/// nothing a person made, so it is the first thing to go:
///
/// - Above normal ``allowsSpares`` is false: the pool makes none and parks none until normal.
/// - At a level that closes them (``Closing``) the pool's spares close in the turn the level changes
///   (`drop`); at a level that does not, the pool only holds them (`hold`).
/// - Back at normal ``allowsSpares`` is true again and the pool is asked to refill once; it makes the
///   spare at its next idle moment, as it always does.
/// - At normal one spare is kept in every Memory Saver mode. A spare's cost is fixed (one page or one
///   window), so a mode's share has nothing to scale: the mode changes only discard timeouts at
///   normal (p07-memory.md section 3.A).
///
/// The level comes from the registration (``MemoryLevelConsumer``), never from a second subscription to
/// the kernel's pressure source. The pool keeps this object; releasing it or calling ``cancel()``
/// ends the registration.
///
/// ```swift
/// spareMemory = SpareMemoryConsumer(
///     name: "page-host-spare", registry: memory, spares: { [weak self] in self?.spareCount ?? 0 },
///     drop: { [weak self] in self?.dropSpare() }, refill: { [weak self] in self?.scheduleBuild() })
/// ```
@MainActor
public final class SpareMemoryConsumer: MemoryLevelConsumer {
    /// The pressure at which a pool's untaken spares close.
    public enum Closing: Sendable {
        /// Warning and critical close them (the page pools, cmux's choice: a page spare comes back at
        /// the next idle moment after normal).
        case atAnyPressure
        /// Only critical closes them; warning keeps the untaken ones and refuses new ones, Chrome's
        /// default for its spare renderer (Chromium's spare windows).
        case atCritical

        /// Whether `level` closes the untaken spares.
        public func closes(at level: MemoryPressureLevel) -> Bool {
            switch (self, level) {
            case (_, .normal), (.atCritical, .warning): false
            case (.atAnyPressure, .warning), (_, .critical): true
            }
        }
    }

    /// A spare: one page or window (1 to 50 MB), nothing read or written to drop it, nothing a person
    /// made, rebuilt by a page load or a window build, and either kept whole or closed (no limit to
    /// scale, so the coordinator never manages it by mode).
    public nonisolated static let traits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .expensive,
        releaseCPUCost: .low, isStateful: false, supportsMemoryLimit: false)

    /// The level the coordinator acts on now; normal until the registration hands the current one.
    public private(set) var level: MemoryPressureLevel = .normal

    /// Whether the pool may make, park or give back a spare now: only at normal pressure.
    public var allowsSpares: Bool {
        level == .normal
    }

    private let closing: Closing
    private let spares: @MainActor () -> Int
    private let hold: (@MainActor () -> Void)?
    private let drop: @MainActor () -> Void
    private let refill: @MainActor () -> Void
    private var registration: MemoryConsumerRegistration?

    /// Registers the pool with `registry`; the current level arrives before this returns, so a pool
    /// made under pressure never warms a spare.
    ///
    /// - Parameters:
    ///   - name: The pool's name in the memory report (stable, kebab-case).
    ///   - registry: The memory coordinator (injected).
    ///   - closing: The pressure at which the untaken spares close; any pressure by default.
    ///   - spares: How many spares the pool holds now, from its own state (the memory report).
    ///   - hold: Refuses new spares and cancels a warm that has not started, keeping the untaken
    ///     ones; runs at each level above normal that `closing` does not close at.
    ///   - drop: Closes the pool's spares, and cancels a warm that has not started; runs at each level
    ///     `closing` closes at.
    ///   - refill: Asks the pool for its next spare at its next idle moment.
    public init(
        name: String,
        registry: any MemoryConsumerRegistry,
        closing: Closing = .atAnyPressure,
        spares: @escaping @MainActor () -> Int,
        hold: (@MainActor () -> Void)? = nil,
        drop: @escaping @MainActor () -> Void,
        refill: @escaping @MainActor () -> Void
    ) {
        self.closing = closing
        self.spares = spares
        self.hold = hold
        self.drop = drop
        self.refill = refill
        registration = MemoryConsumerRegistration(name: name, traits: Self.traits, consumer: self, registry: registry)
    }

    /// Ends the registration now: no level reaches the pool after this.
    public func cancel() {
        registration?.cancel()
        registration = nil
    }

    public func memoryLevelDidChange(_ newLevel: MemoryPressureLevel) {
        let wasAllowed = allowsSpares
        level = newLevel
        if closing.closes(at: newLevel) {
            drop()
        } else if !allowsSpares {
            hold?()
        } else if !wasAllowed {
            refill()
        }
    }

    /// A spare has no size to scale: the level, not the limit, decides whether it stays.
    public func updateMemoryLimit(_ limit: MemoryLimit) {}

    /// Nothing to release in a slice: the level's own turn closed the spares, and no pool makes,
    /// parks or gives one back until normal (``allowsSpares``).
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        .done
    }

    /// No spare is nothing held; a spare's bytes live mostly in its web content or renderer process,
    /// which this process cannot read, so its size is unknown, never 0.
    public var memoryUsage: MemoryUsage? {
        spares() == 0 ? .empty : nil
    }
}
