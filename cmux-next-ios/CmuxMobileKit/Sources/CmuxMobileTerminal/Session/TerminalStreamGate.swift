#if os(iOS)
import CmuxMobileLinkFFI
import Foundation

/// Whether a terminal page's session receives the Mac's output now (Leo,
/// 2026-11-14: "surely we don't need to stream the f***ing thing"). The
/// decision is Rust's (`terminal_stream_plan`, cmux-mobile-link-ffi
/// `terminal_stream.rs`): on screen in the foreground it streams; off screen
/// for 3 s, or in the background for 45 s (the size claim is released at once), it stops,
/// and the page keeps its grid and last frame as the cache. Shown again, the
/// session attaches once and the Mac's replay brings the page up to date.
///
/// This drives it with a clock: feed it the page's states, it tells the
/// session through `apply` and looks again when the plan says to.
@MainActor
public final class TerminalStreamGate<C: Clock> where C.Duration == Duration {
    private let clock: C
    private let apply: @MainActor (Bool) -> Void
    private var pageShown = false
    private var appActive = true
    /// A page tells the gate where it is (`TerminalTabPage`). Until then
    /// nothing decides: a screen with no page around it (the full-screen
    /// terminal, the flood bench) streams as before.
    private var driven = false
    /// When the page last left the screen (a page that appeared off screen:
    /// when it appeared).
    private var offScreenSince: C.Instant?
    /// When the app last left the foreground.
    private var backgroundSince: C.Instant?
    private var pending: Task<Void, Never>?
    /// What the session was last told. A session starts streaming.
    public private(set) var streaming = true

    public init(clock: C, apply: @escaping @MainActor (Bool) -> Void) {
        self.clock = clock
        self.apply = apply
    }

    public func set(pageShown: Bool) {
        guard !driven || self.pageShown != pageShown else { return }
        driven = true
        self.pageShown = pageShown
        offScreenSince = pageShown ? nil : clock.now
        recheck()
    }

    public func set(appActive: Bool) {
        guard self.appActive != appActive else { return }
        self.appActive = appActive
        backgroundSince = appActive ? nil : clock.now
        if driven { recheck() }
    }

    /// Stops a pending look (the page went away for good).
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        let ms = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        return UInt64(max(0, ms))
    }

    private func recheck() {
        pending?.cancel()
        pending = nil
        let now = clock.now
        let plan = terminalStreamPlan(facts: TerminalStreamFacts(
            pageShown: pageShown,
            appActive: appActive,
            offScreenMs: offScreenSince.map { Self.milliseconds($0.duration(to: now)) },
            backgroundMs: backgroundSince.map { Self.milliseconds($0.duration(to: now)) }
        ))
        if plan.stream != streaming {
            streaming = plan.stream
            apply(plan.stream)
        }
        guard let wait = plan.recheckInMs else { return }
        // An intentional, bounded delay on the injected clock (the grace the
        // plan names), not a synchronization wait.
        let clock = clock
        let due = now.advanced(by: .milliseconds(Int64(clamping: wait)))
        pending = Task { [weak self] in
            do { try await clock.sleep(until: due, tolerance: nil) } catch { return }
            guard !Task.isCancelled else { return }
            self?.recheck()
        }
    }
}
#endif
