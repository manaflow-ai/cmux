import CmuxNextDesignTokens
import CmuxNextWakeups
import Foundation

/// Closed chat pages kept whole for a while, so Reopen Closed takes one back loaded, connected
/// and drawn instead of building a cold page (Leo 2026-11-07: "it should load a lot faster").
/// Bounded: at most `limit` pages, each for `keepFor`; Low Power Mode keeps none. A page that
/// leaves the keep without being taken goes to `teardown`, also when Low Power Mode turns on. Its one timer and
/// its power-state observer stop once nothing is kept.
@MainActor
public final class ClosedPageKeeper<Page: AnyObject> {
    private var kept: ClosedPageKeep<Page>
    private let keepFor: Duration
    private let timer: DemandTimer
    private let clock = ContinuousClock()
    private let teardown: @MainActor (Page) -> Void
    /// Low Power Mode turning on empties the keep; observed only while something is kept.
    private var powerObservation: LowPowerModeObservation?

    public init(limit: Int, keepFor: Duration, owner: String, teardown: @escaping @MainActor (Page) -> Void) {
        kept = ClosedPageKeep(limit: limit)
        self.keepFor = keepFor
        timer = DemandTimer(owner: owner)
        self.teardown = teardown
    }

    nonisolated deinit {}

    /// Watches the power state while pages are kept: Low Power Mode keeps none, also those kept before it turned on.
    private func observePower() {
        guard !kept.isEmpty else {
            powerObservation = nil
            return
        }
        guard powerObservation == nil else { return }
        powerObservation = LowPowerMode.system.observe { [weak self] enabled in
            if enabled { self?.lowPowerChanged() }
        }
    }

    private func lowPowerChanged() {
        for page in kept.removeAll() { teardown(page) }
        timer.cancel()
        observePower()
    }

    /// Keeps `page` of closed chat `session`; false (nothing kept) in Low Power Mode.
    public func keep(_ page: Page, for session: String) -> Bool {
        // The shared state, override included: the observer reports only changes, so a mode already
        // on at the close (`debug.low_power_mode`) is read here.
        guard !LowPowerMode.system.isEnabled else { return false }
        for dropped in kept.keep(page, for: session, until: clock.now + keepFor) { teardown(dropped) }
        scheduleExpiry()
        observePower()
        return true
    }

    /// Every kept page, by the session it shows.
    public var pages: [(session: String, page: Page)] { kept.pages }

    /// The kept page of closed chat `session`, taken back (nil when none is kept).
    public func take(_ session: String) -> Page? {
        // Low Power Mode since the close: nothing is used from the keep, and it empties now.
        if LowPowerMode.system.isEnabled {
            for page in kept.removeAll() { teardown(page) }
            timer.cancel()
            observePower()
            return nil
        }
        let page = kept.take(session)
        if kept.isEmpty { timer.cancel() }
        observePower()
        return page
    }

    private func scheduleExpiry() {
        guard let soonest = kept.soonest else {
            timer.cancel()
            return
        }
        timer.schedule(after: max(.zero, clock.now.duration(to: soonest))) { @MainActor [weak self] in
            guard let self else { return }
            for expired in kept.expire(at: clock.now) { teardown(expired) }
            scheduleExpiry()
            observePower()
        }
    }
}

/// The pages ``ClosedPageKeeper`` holds, by the session they show: at most `limit` (the oldest
/// goes first), one per session, each until its deadline.
public struct ClosedPageKeep<Page: AnyObject> {
    public let limit: Int
    private var entries: [(session: String, page: Page, until: ContinuousClock.Instant)] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public var isEmpty: Bool { entries.isEmpty }
    public var pages: [(session: String, page: Page)] { entries.map { ($0.session, $0.page) } }
    public var soonest: ContinuousClock.Instant? { entries.map(\.until).min() }

    /// Keeps `page` for `session` until `until`; returns the pages it pushed out (an older page
    /// of the same session, the oldest past `limit`).
    public mutating func keep(_ page: Page, for session: String, until: ContinuousClock.Instant) -> [Page] {
        var dropped = entries.filter { $0.session == session }.map(\.page)
        entries.removeAll { $0.session == session }
        entries.append((session, page, until))
        while entries.count > limit { dropped.append(entries.removeFirst().page) }
        return dropped
    }

    /// The kept page of `session`, no longer kept.
    public mutating func take(_ session: String) -> Page? {
        guard let index = entries.firstIndex(where: { $0.session == session }) else { return nil }
        return entries.remove(at: index).page
    }

    /// Every kept page, no longer kept.
    public mutating func removeAll() -> [Page] {
        defer { entries.removeAll() }
        return entries.map(\.page)
    }

    /// The pages whose time ended at `now`, no longer kept.
    public mutating func expire(at now: ContinuousClock.Instant) -> [Page] {
        let ended = entries.filter { $0.until <= now }.map(\.page)
        entries.removeAll { $0.until <= now }
        return ended
    }
}
