public import Foundation

/// Debounces the browser panel's page-loading indicator so very fast navigations never flash it.
///
/// This coordinator owns the small timing policy the browser panel used to inline as
/// `handleWebViewLoadingChanged(_:)` plus its stored `loadingStartedAt` / `loadingEndWorkItem` /
/// `loadingGeneration` / `minLoadingIndicatorDuration` machinery. The panel keeps the published
/// `isLoading` mirror and every side effect (favicon reset, hidden-web-view discard scheduling);
/// those are driven back to the panel through ``onLoadingStarted`` / ``onLoadingEnded`` so no
/// WebKit or AppKit type crosses into this package.
///
/// Policy, preserved one-for-one from the panel body:
/// - On load-start: bump the generation, cancel any pending delayed end, stamp the start time,
///   and tell the panel loading began (panel cancels hidden-web-view discard, resets the favicon
///   service, clears the favicon image, and flips its `isLoading` mirror to `true`).
/// - On load-end: compute `remaining = max(0, minLoadingIndicatorDuration - elapsed)`. If the
///   indicator has already shown long enough (`remaining <= 0.0001`), tell the panel loading
///   ended immediately. Otherwise arm a generation-guarded delayed end that fires after
///   `remaining`, and only tells the panel loading ended if the generation still matches and
///   WebKit is no longer loading (read through ``isLoadingProvider``).
///
/// Timing-mechanism delta from the original: the legacy end used a `DispatchWorkItem` armed with
/// `DispatchQueue.main.asyncAfter(deadline:execute:)` and cancelled via `loadingEndWorkItem.cancel()`.
/// This coordinator replaces that with an injected, cancellable ``Sleep`` (default `ContinuousClock`)
/// run inside a `Task`, per the refactor's Clock-over-asyncAfter rule. Cancellation is wired to the
/// generation bump rather than to an explicit work-item handle: a newer load-start (or any reset that
/// calls ``cancelPendingEnd()``) cancels the pending `Task`, whose `sleep` throws on cancel and drops
/// the stale end; the post-sleep `loadingGeneration == genAtEnd` guard absorbs every remaining
/// stale-fire race exactly as the legacy `guard self.loadingGeneration == genAtEnd` did. Observable
/// behavior is identical: the same `remaining` deadline, the same generation guard, the same
/// `webView.isLoading` recheck, and the same single `onLoadingEnded` callback. The only difference an
/// observer could see is that the delay now runs on `ContinuousClock` (suspending) instead of the main
/// dispatch queue's wall-clock timer; both fire on the main actor after the same nominal duration.
///
/// Lifecycle: the panel constructs one coordinator (injecting `minLoadingIndicatorDuration`, the
/// `Clock`-backed sleep, the `webView.isLoading` provider, and its two side-effect callbacks),
/// forwards each KVO `isLoading` change to ``loadingChanged(_:)``, and calls ``cancelPendingEnd()``
/// from every web-view discard / context-reset path that used to cancel `loadingEndWorkItem`. All
/// state is `@MainActor`-isolated, matching the panel that owns the single instance.
@MainActor
public final class BrowserLoadingIndicatorDebounceCoordinator {
    /// Invoked when a load starts. The panel cancels hidden-web-view discard, resets its favicon
    /// service, clears the favicon image, and flips its `isLoading` mirror to `true`.
    public typealias OnLoadingStarted = @MainActor () -> Void

    /// Invoked when a load is considered finished (immediately, or after the debounce delay). The
    /// panel flips its `isLoading` mirror to `false` and schedules hidden-web-view discard.
    public typealias OnLoadingEnded = @MainActor () -> Void

    /// Reads whether WebKit is still loading, so the delayed end can ignore a still-in-flight load.
    /// Mirrors the legacy `guard !self.webView.isLoading` recheck without importing WebKit.
    public typealias IsLoadingProvider = @MainActor () -> Bool

    /// Suspends for `duration` and is cancelled when the pending end task is cancelled, giving the
    /// same debounce cadence the legacy `DispatchQueue.main.asyncAfter` had.
    public typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    /// Minimum time the loading indicator stays visible once shown, so fast navigations do not flash
    /// it (the legacy `minLoadingIndicatorDuration`, default 0.35s).
    private let minLoadingIndicatorDuration: TimeInterval
    private let sleep: Sleep
    private let isLoadingProvider: IsLoadingProvider
    private let onLoadingStarted: OnLoadingStarted
    private let onLoadingEnded: OnLoadingEnded

    /// Wall-clock stamp of the most recent load-start, used to compute the elapsed indicator time.
    private var loadingStartedAt: Date?
    /// Monotonic counter bumped on every load-start; a delayed end only fires if the generation it
    /// captured still matches, which is also the cancellation signal for the pending end task.
    private var loadingGeneration: Int = 0
    /// The pending delayed end, replacing the legacy `loadingEndWorkItem: DispatchWorkItem`.
    private var pendingEndTask: Task<Void, Never>?

    /// Creates a loading-indicator debounce coordinator with its effect seams injected.
    /// - Parameters:
    ///   - minLoadingIndicatorDuration: Minimum visible duration once shown (default 0.35s).
    ///   - sleep: Cancellable timing source; defaults to `ContinuousClock`.
    ///   - isLoadingProvider: Reads the live web view's `isLoading` flag.
    ///   - onLoadingStarted: Panel-side load-start side effects + `isLoading = true`.
    ///   - onLoadingEnded: Panel-side load-end side effects + `isLoading = false`.
    public init(
        minLoadingIndicatorDuration: TimeInterval = 0.35,
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) },
        isLoadingProvider: @escaping IsLoadingProvider,
        onLoadingStarted: @escaping OnLoadingStarted,
        onLoadingEnded: @escaping OnLoadingEnded
    ) {
        self.minLoadingIndicatorDuration = minLoadingIndicatorDuration
        self.sleep = sleep
        self.isLoadingProvider = isLoadingProvider
        self.onLoadingStarted = onLoadingStarted
        self.onLoadingEnded = onLoadingEnded
    }

    /// Processes a web-view loading-state change, reproducing the legacy
    /// `handleWebViewLoadingChanged(_:)` body exactly.
    /// - Parameter newValue: The new `webView.isLoading` value reported by KVO.
    public func loadingChanged(_ newValue: Bool) {
        if newValue {
            loadingGeneration &+= 1
            pendingEndTask?.cancel()
            pendingEndTask = nil
            loadingStartedAt = Date()
            onLoadingStarted()
            return
        }

        let genAtEnd = loadingGeneration
        let startedAt = loadingStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, minLoadingIndicatorDuration - elapsed)

        pendingEndTask?.cancel()
        pendingEndTask = nil

        if remaining <= 0.0001 {
            onLoadingEnded()
            return
        }

        pendingEndTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(.seconds(remaining))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // If loading restarted, ignore this end.
            guard self.loadingGeneration == genAtEnd else { return }
            // If WebKit is still loading, ignore.
            guard !self.isLoadingProvider() else { return }
            self.onLoadingEnded()
        }
    }

    /// Cancels any pending delayed end and bumps the generation, matching every legacy site that did
    /// `loadingEndWorkItem?.cancel(); loadingEndWorkItem = nil; loadingGeneration &+= 1` during a
    /// web-view discard or context reset. Callers that also flip the panel's `isLoading` mirror to
    /// `false` keep doing so panel-side; this only tears down the timer machinery.
    public func cancelPendingEnd() {
        pendingEndTask?.cancel()
        pendingEndTask = nil
        loadingGeneration &+= 1
    }
}
