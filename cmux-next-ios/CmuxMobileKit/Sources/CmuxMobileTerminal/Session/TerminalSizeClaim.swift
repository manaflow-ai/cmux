import Foundation

/// When a terminal's page claims its size on the Mac (cmux-next-ios/PROTOCOL.md,
/// "Terminal size claims"): only while the page is on screen, settled and
/// taking input (`pageShown`), the app is in the foreground (`appActive`) and
/// no sheet covers it (`covered`). Pure: states and instants in, a change for
/// the session and the next instant to look again out.
///
/// Leaving the page (back, another tab, the grid, a sheet) releases after
/// `delay`, so switching away and back quickly never resizes the Mac's pane
/// twice. The app going to the background (another app, the lock screen)
/// releases after `backgroundDelay`, the Mac's size lease: back within it,
/// nothing was sent and nothing reflows (Leo, 2026-11-14: "we want to bring
/// back the 45 ... seconds"); gone longer, the Mac's pane has its own size
/// back (Leo, 2026-11-12: "if I do completely switch away, I want to be
/// gone"). A suspended app's timer never fires, so a release that fell due
/// while it was away goes out on its return, before the claim. Coming back
/// after a release claims at once; the page from before holds until the
/// reclaim's replay, so the Mac's wider grid is never painted
/// (`TerminalViewController.appActiveChanged`).
public struct TerminalSizeClaimDebounce<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    public static var defaultDelay: Duration { .seconds(1) }
    /// The Mac's size lease (`size-lease-v1`, 45 s), which ends a suspended
    /// phone's claim on the Mac at the same time.
    public static var backgroundDelay: Duration { .seconds(45) }

    public let delay: Duration
    public var pageShown = false
    public var appActive = true
    public var covered = false
    /// What the session was last told. A session starts claiming.
    public private(set) var claims = true
    /// When a pending release goes out.
    public private(set) var releaseAt: Instant?

    public init(delay: Duration = .seconds(1)) {
        self.delay = delay
    }

    public var wanted: Bool { pageShown && appActive && !covered }

    /// The states at `now`: the session's new claim (nil: unchanged) and
    /// when to call again (nil: nothing changes without a new state).
    public mutating func update(at now: Instant) -> (claims: Bool?, recheck: Instant?) {
        if wanted {
            // Due while the app was suspended: the release first (the
            // Mac's lease has ended too), the claim on the next look.
            if claims, let due = releaseAt, now >= due {
                releaseAt = nil
                claims = false
                return (false, now)
            }
            releaseAt = nil
            guard !claims else { return (nil, nil) }
            claims = true
            return (true, nil)
        }
        guard claims else {
            releaseAt = nil
            return (nil, nil)
        }
        // The page left (or a sheet covers it): `delay`. The app left the
        // foreground: `backgroundDelay`. A release already pending keeps
        // its time.
        let at = releaseAt ?? now.advanced(by: appActive ? delay : Self.backgroundDelay)
        guard now < at else {
            releaseAt = nil
            claims = false
            return (false, nil)
        }
        releaseAt = at
        return (nil, at)
    }
}

/// Drives a `TerminalSizeClaimDebounce` with a clock: feed it the page's
/// states; it tells the session through `apply`.
@MainActor
public final class TerminalSizeClaimer<C: Clock> where C.Duration == Duration {
    private var debounce: TerminalSizeClaimDebounce<C.Instant>
    private let clock: C
    private let apply: @MainActor (Bool) -> Void
    private var pending: Task<Void, Never>?

    public init(clock: C, delay: Duration = .seconds(1), apply: @escaping @MainActor (Bool) -> Void) {
        self.clock = clock
        self.apply = apply
        debounce = TerminalSizeClaimDebounce(delay: delay)
        // A session starts claiming; a page that is never shown gives it up
        // after the delay (its page's appearance sets it shown first).
        recheck()
    }

    public var claims: Bool { debounce.claims }

    public func set(pageShown: Bool) {
        guard debounce.pageShown != pageShown else { return }
        debounce.pageShown = pageShown
        recheck()
    }

    public func set(appActive: Bool) {
        guard debounce.appActive != appActive else { return }
        debounce.appActive = appActive
        recheck()
    }

    public func set(covered: Bool) {
        guard debounce.covered != covered else { return }
        debounce.covered = covered
        recheck()
    }

    /// Stops a pending release (the page went away for good).
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func recheck() {
        var (change, next) = debounce.update(at: clock.now)
        pending?.cancel()
        pending = nil
        if let change { apply(change) }
        // An overdue release went out: the claim goes now, not a tick later.
        if let due = next, due <= clock.now {
            (change, next) = debounce.update(at: clock.now)
            if let change { apply(change) }
        }
        guard let next else { return }
        // An intentional, bounded delay on the injected clock (the release
        // debounce), not a synchronization wait.
        let clock = clock
        pending = Task { [weak self] in
            do { try await clock.sleep(until: next, tolerance: nil) } catch { return }
            self?.recheck()
        }
    }
}
