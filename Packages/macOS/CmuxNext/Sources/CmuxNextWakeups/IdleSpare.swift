/// One value made ahead of the key that needs it, as Chrome keeps a spare renderer for its next tab (TERMINAL CREATE
/// COST item 2: a New Column's pane views cost 3.5 ms of its key turn). ``take()`` hands it out in the key's turn and
/// makes nothing. Its owner calls ``fill()`` when the app is still (no layout motion, the key's frame committed); the
/// value is then made as one background task on the app's scheduler, which yields to the person's input.
///
/// ```swift
/// let spare = IdleSpare(owner: "PaneSpare", on: mainWork) { PaneController.Spare(services: services) }
/// let views = spare.take() ?? PaneController.Spare(services: services) // the key's turn
/// ```
@MainActor
public final class IdleSpare<Value> {
    private let queue: FrameBatchQueue
    private let make: @MainActor () -> Value?
    /// The value made ahead, if any.
    public private(set) var ready: Value?
    private var isMaking = false
    /// Off: nothing is made, and a make already queued does nothing (motion runs, the owner is parked or gone).
    public var isWanted = true

    /// - Parameters:
    ///   - owner: names the background queue in the wakeup ledger and the watchdog's records.
    ///   - work: the app's main-thread scheduler.
    ///   - make: makes one value (nil: its owner is gone); runs as a background task, never in a key's turn.
    public init(owner: String, on work: MainWorkScheduler, make: @escaping @MainActor () -> Value?) {
        queue = FrameBatchQueue(owner: owner, budgeted: .background, on: work)
        self.make = make
    }

    // Generic main-actor class: no isolated deinit (swift-frontend 6.3.3 crashes on one in -O; check-concurrency).
    nonisolated deinit {}

    /// The value made ahead, or nil when none is ready. Makes nothing: the owner calls ``fill()`` once it is still.
    public func take() -> Value? {
        defer { ready = nil }
        return ready
    }

    /// Drops the value made ahead (its owner hides).
    public func drop() { ready = nil }

    /// Makes the value as background work when none is ready and it is wanted.
    public func fill() {
        guard isWanted, ready == nil, !isMaking else { return }
        isMaking = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            isMaking = false
            guard isWanted, ready == nil else { return }
            ready = make()
        }
    }
}
