public import Foundation
import Observation

/// Debounces find-in-page needle edits and forwards each settled query to the panel.
///
/// This coordinator owns the small policy the browser panel used to inline as a Combine
/// pipeline on `BrowserSearchState.$needle`
/// (`removeDuplicates().map { … delay … }.switchToLatest().sink { executeFindSearch }`).
/// It observes the `@Observable` ``BrowserSearchState/needle`` through
/// `withObservationTracking` instead of a Combine `$needle` projection, which is the last
/// consumer that kept the find domain on Combine. The observed state stays `@Observable`;
/// only the consumer moves here.
///
/// Policy, preserved one-for-one from the Combine pipeline:
/// - duplicate consecutive needle values are dropped (the old `removeDuplicates()`);
/// - an empty needle or a needle of three or more characters is forwarded immediately;
/// - a shorter non-empty needle is forwarded after a 300 ms delay;
/// - a newer needle cancels any still-pending delayed forward (the old `switchToLatest()`).
///
/// The 300 ms wait is an injected, cancellable ``Sleep`` (default `ContinuousClock`) rather
/// than Combine's `.delay(for:scheduler:)` or `DispatchQueue.asyncAfter`, per the refactor's
/// Clock-over-asyncAfter rule: the pending forward is a `Task` whose `sleep` throws on
/// cancellation, so re-arming or tearing down cleanly drops the stale forward and there is no
/// uncancellable work item. Tests inject a deterministic clock.
///
/// Lifecycle: the panel constructs one coordinator per `searchState` it creates (injecting the
/// `Clock`-backed sleep and wiring `onNeedle` to its `executeFindSearch`), calls ``observe(_:)``
/// to seed observation, and calls ``stop()`` when it clears `searchState`. All state is
/// `@MainActor`-isolated, matching the panel that owns the single instance.
@MainActor
@Observable
public final class BrowserFindNeedleDebounceCoordinator {
    /// Sink invoked with each settled needle value (the panel forwards it to its find search).
    public typealias OnNeedle = @MainActor (_ needle: String) -> Void

    /// Suspends for `duration` and is cancelled when the pending forward task is cancelled,
    /// giving the same debounce cadence the Combine `.delay` had.
    public typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    /// Delay applied to a non-empty needle shorter than ``immediateThreshold`` characters
    /// (matches the original `.delay(for: .milliseconds(300), scheduler: DispatchQueue.main)`).
    public static let debounceDelay: Duration = .milliseconds(300)

    /// Needle length at or above which a forward is immediate rather than delayed
    /// (matches the original `needle.count >= 3` immediate branch).
    public static let immediateThreshold: Int = 3

    private let onNeedle: OnNeedle
    private let sleep: Sleep

    private var observedState: BrowserSearchState?
    /// Last value actually forwarded, reproducing the Combine `removeDuplicates()` drop of
    /// consecutive equal needles. `nil` until the first forward.
    private var lastForwarded: String?
    private var pendingTask: Task<Void, Never>?

    /// Creates a debounce coordinator with its effect seams injected.
    /// - Parameters:
    ///   - onNeedle: Sink for each settled needle value.
    ///   - sleep: Cancellable timing source; defaults to `ContinuousClock`.
    public init(
        onNeedle: @escaping OnNeedle,
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) }
    ) {
        self.onNeedle = onNeedle
        self.sleep = sleep
    }

    /// Begins observing `state.needle` and processes its current value.
    ///
    /// Seeding processes the state's initial needle exactly as the Combine subscription did:
    /// `CurrentValueSubject`-style replay of the current value on subscribe, subject to the same
    /// dedup and delay policy. Each subsequent `needle` mutation re-registers observation and is
    /// processed again, reproducing the continuous `$needle` stream.
    /// - Parameter state: The find-in-page state whose needle drives the search.
    public func observe(_ state: BrowserSearchState) {
        observedState = state
        lastForwarded = nil
        scheduleObservation()
        process(state.needle)
    }

    /// Stops observation and cancels any pending delayed forward, matching the panel dropping its
    /// Combine cancellable when `searchState` is cleared.
    public func stop() {
        observedState = nil
        lastForwarded = nil
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func scheduleObservation() {
        withObservationTracking { [weak self] in
            _ = self?.observedState?.needle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let state = self.observedState else { return }
                self.scheduleObservation()
                self.process(state.needle)
            }
        }
    }

    private func process(_ needle: String) {
        guard lastForwarded != needle else { return }

        if needle.isEmpty || needle.count >= Self.immediateThreshold {
            pendingTask?.cancel()
            pendingTask = nil
            forward(needle)
            return
        }

        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(Self.debounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.forward(needle)
        }
    }

    private func forward(_ needle: String) {
        lastForwarded = needle
        onNeedle(needle)
    }
}
