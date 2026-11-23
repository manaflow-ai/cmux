import Foundation
import Observation

/// When a dropped connection may say so on screen: nothing while it is down
/// for less than ``threshold`` (a blip on a phone network, a reattach after
/// the app comes back), then one quiet line near the composer. The cached
/// screen (terminal frame, chat rows, list rows) stays on screen the whole
/// time; this only decides when the small status line appears.
///
/// Leo, 2026-11-12, on LTE: "wack reconnection state / just show the cache".
@MainActor
@Observable
public final class QuietStatusGate {
    /// How long a connection is down before its line shows.
    public static let threshold: Duration = .seconds(10)

    /// The line may show now (down for at least `delay`).
    public private(set) var isShown = false
    @ObservationIgnored public let delay: Duration
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var down = false
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init(delay: Duration = QuietStatusGate.threshold, clock: any Clock<Duration> = ContinuousClock()) {
        self.delay = delay
        self.clock = clock
    }

    /// The connection is down (true) or back (false). Repeating `true` keeps
    /// the first instant: a reattach that retries does not restart the wait.
    public func update(down: Bool) {
        guard down else {
            self.down = false
            pending?.cancel()
            pending = nil
            if isShown { isShown = false }
            return
        }
        guard pending == nil, !isShown else { return }
        if delay <= .zero {
            isShown = true
            return
        }
        self.down = true
        let delay = delay
        let clock = clock
        // An intentional, bounded UI delay on the injected clock (not a sync wait).
        pending = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.down else { return }
            self.pending = nil
            self.isShown = true
        }
    }
}
