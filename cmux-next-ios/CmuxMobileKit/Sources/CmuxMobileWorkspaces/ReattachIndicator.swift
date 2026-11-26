import Observation

/// When the title pill says "Reattaching…" (design/terminal P5): only once a
/// reattach has lasted `delay` (400 ms). A quick reattach (the usual 250 ms
/// return from the background) shows nothing. Pure: states and instants in,
/// a yes/no and the next instant to look again out.
public struct ReattachDebounce<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    public static var defaultDelay: Duration { .milliseconds(400) }

    public let delay: Duration
    /// When the current reattach began; nil while attached (or connecting).
    public private(set) var since: Instant?

    public init(delay: Duration = .milliseconds(400)) {
        self.delay = delay
    }

    /// Records the state at `now`. Returns when to call `isShown` again (the
    /// moment the indicator would appear), or nil when nothing will change
    /// without a new state.
    public mutating func update(reattaching: Bool, at now: Instant) -> Instant? {
        guard reattaching else {
            since = nil
            return nil
        }
        let start = since ?? now
        since = start
        return isShown(at: now) ? nil : start.advanced(by: delay)
    }

    /// Whether the indicator shows at `now`.
    public func isShown(at now: Instant) -> Bool {
        guard let since else { return false }
        return since.duration(to: now) >= delay
    }
}

/// Drives a `ReattachDebounce` with a clock: feed it the terminal's state,
/// read `isShown` (observable) from the tab's subtitle.
@MainActor
@Observable
public final class ReattachIndicator<C: Clock> where C.Duration == Duration {
    public private(set) var isShown = false
    /// The Mac is offline: the pill says so at once, with no reattach debounce
    /// (termfix-r13 D4: "Reattaching…" stayed for 20 minutes).
    public private(set) var isOffline = false

    public func update(offline: Bool) {
        if isOffline != offline { isOffline = offline }
        if offline { update(reattaching: false) }
    }
    @ObservationIgnored private var debounce: ReattachDebounce<C.Instant>
    @ObservationIgnored private let clock: C
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init(clock: C, delay: Duration = .milliseconds(400)) {
        self.clock = clock
        debounce = ReattachDebounce(delay: delay)
    }

    public func update(reattaching: Bool) {
        let now = clock.now
        let next = debounce.update(reattaching: reattaching, at: now)
        show(debounce.isShown(at: now))
        pending?.cancel()
        pending = nil
        guard let next else { return }
        // An intentional, bounded delay on the injected clock (not a sync wait).
        let clock = clock
        pending = Task { [weak self] in
            do { try await clock.sleep(until: next, tolerance: nil) } catch { return }
            self?.recheck()
        }
    }

    /// Stops a pending check (the tab went away).
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func recheck() {
        show(debounce.isShown(at: clock.now))
    }

    private func show(_ shown: Bool) {
        if isShown != shown { isShown = shown }
    }
}

extension ReattachIndicator where C == ContinuousClock {
    public convenience init() {
        self.init(clock: ContinuousClock())
    }
}
