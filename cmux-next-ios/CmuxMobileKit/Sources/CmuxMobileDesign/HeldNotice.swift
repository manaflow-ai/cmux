import Foundation

/// One notice slot whose quiet notices wait before they show. A link coming
/// up or coming back, which the person can do nothing about, shows nothing
/// until it lasted the shared bound (``QuietStatusGate/threshold``, 10 s, for a
/// first connect and a reconnect alike); a notice with an action (offline with
/// Retry, can't reach, sign in) shows at once. ``shown`` is what is on screen now.
///
/// Leo, 2026-11-16: "it took like 7 seconds to reconnect or whatever to this
/// chat on ios and it said "Not connected"'at the top but i dont think it
/// shoildve said anything".
@MainActor
public final class HeldNotice<Value: Equatable> {
    /// The notice on screen now (nil: none).
    public private(set) var shown: Value?
    private var held: Value?
    private var pending: Task<Void, Never>?
    private let clock: any Clock<Duration>
    private let changed: @MainActor (Value?) -> Void

    /// `changed` gets every new `shown` (the owner mirrors it into its observed state).
    public init(clock: any Clock<Duration> = ContinuousClock(), changed: @escaping @MainActor (Value?) -> Void = { _ in }) {
        self.clock = clock
        self.changed = changed
    }

    /// A quiet notice: it shows once a quiet stretch lasted `delay`. Another
    /// quiet notice while one waits or shows replaces it without restarting
    /// the wait (a redial that retries is the same outage).
    public func hold(_ value: Value, for delay: Duration) {
        if held != nil, pending == nil {
            // Already past its wait and on screen: the newer wording shows.
            held = value
            set(value)
            return
        }
        held = value
        guard pending == nil else { return }
        if delay <= .zero {
            set(value)
            return
        }
        let clock = clock
        // An intentional, bounded UI delay on the injected clock (not a sync wait).
        pending = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, let held = self.held else { return }
            self.pending = nil
            self.set(held)
        }
    }

    /// A notice that shows at once (one with an action), or nil for none; it
    /// ends any quiet wait.
    public func show(_ value: Value?) {
        pending?.cancel()
        pending = nil
        held = nil
        set(value)
    }

    private func set(_ value: Value?) {
        guard shown != value else { return }
        shown = value
        changed(value)
    }
}
