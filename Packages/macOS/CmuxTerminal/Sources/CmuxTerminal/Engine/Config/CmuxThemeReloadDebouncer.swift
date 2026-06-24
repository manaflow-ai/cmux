public import Foundation

extension Notification.Name {
    /// The distributed-notification name cmux's theme tooling posts to ask the
    /// app to reload its Ghostty configuration.
    ///
    /// Replaces the app-target caseless `enum CmuxThemeNotifications` namespace
    /// (one `Notification.Name`) per the no-namespace-enum convention. The app
    /// registers a `DistributedNotificationCenter` observer for this name and
    /// forwards into ``CmuxThemeReloadDebouncer``.
    public static let cmuxThemeReloadConfig =
        Notification.Name("com.cmuxterm.themes.reload-config")
}

/// Debounces theme-driven Ghostty configuration reloads.
///
/// cmux's theme tooling posts a stream of reload requests while the user drags a
/// color picker (the preview phase). Reloading the engine on every request would
/// thrash. This coordinator coalesces preview/legacy requests onto a single
/// trailing-edge reload after a quiet window, while letting non-debounced
/// sources (the final "apply" phase) reload immediately.
///
/// ## Why this exists (the banned-primitive replacement)
///
/// The previous inline implementation lived on `AppDelegate` as a
/// `cmuxThemePreviewReloadGeneration` counter plus a
/// `cmuxThemePreviewReloadWorkItem: DispatchWorkItem?` scheduled with
/// `DispatchQueue.main.asyncAfter`, which `CONVENTIONS` §5 and the repo
/// `CLAUDE.md` ban (a `DispatchWorkItem` debounce is not cancellable through the
/// lifecycle and not testable). This replaces it with a structured `Task` that
/// sleeps on an injected `any Clock<Duration>`. Tests pass a virtual clock to
/// advance the deadline deterministically; production passes a `ContinuousClock`.
/// The 180 ms cadence and the generation-cancel semantics are preserved exactly.
///
/// ## Cancellation via generation guard
///
/// Each armed reload carries a monotonic `generation`. A new debounced request
/// bumps the generation and cancels the prior task; an immediate (non-debounced)
/// request bumps it too so any in-flight debounced fire is absorbed as a stale
/// no-op. After the sleep the task only reloads when its captured generation
/// still matches, so a stale fire is idempotent even if the cancel races. This
/// mirrors the legacy `workItem?.cancel()` + `generation == self.generation`
/// guard contract exactly.
///
/// ## Isolation
///
/// `@MainActor` because every request, the reload sink, and the engine reload
/// all run on the main thread in the legacy bodies.
@MainActor
public final class CmuxThemeReloadDebouncer {
    /// The debounce window for coalesced theme reloads.
    ///
    /// Frozen at the legacy 180 ms `asyncAfter` deadline
    /// (`cmuxThemePreviewReloadDebounceMilliseconds`).
    public static var defaultDebounce: Duration { .milliseconds(180) }

    private let reload: (String) -> Void
    private let shouldDebounce: (String) -> Bool
    private let clock: any Clock<Duration>
    private let debounce: Duration

    private var generation = 0
    private var pendingTask: Task<Void, Never>?

    /// Creates a theme-reload debouncer.
    ///
    /// - Parameters:
    ///   - clock: The clock the debounce window sleeps on. Defaults to
    ///     `ContinuousClock()`; tests inject a virtual clock.
    ///   - debounce: The quiet-window duration. Defaults to ``defaultDebounce``
    ///     (the legacy 180 ms deadline).
    ///   - shouldDebounce: Whether a given reload source should be coalesced
    ///     (legacy `GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload`).
    ///     Preview/legacy sources debounce; the final apply source does not.
    ///   - reload: The reload sink invoked with the source string (legacy
    ///     `reloadConfiguration(source:)` driving `GhosttyApp.shared.engineRuntime`).
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = CmuxThemeReloadDebouncer.defaultDebounce,
        shouldDebounce: @escaping (String) -> Bool,
        reload: @escaping (String) -> Void
    ) {
        self.clock = clock
        self.debounce = debounce
        self.shouldDebounce = shouldDebounce
        self.reload = reload
    }

    /// Requests a theme-driven configuration reload for `source`.
    ///
    /// Debounced sources arm a trailing-edge reload after the quiet window,
    /// cancelling any prior armed reload. Non-debounced sources cancel any
    /// pending reload and reload immediately.
    public func request(source: String) {
        if shouldDebounce(source) {
            generation += 1
            let generation = generation
            pendingTask?.cancel()
            let clock = clock
            let debounce = debounce
            pendingTask = Task { @MainActor [weak self] in
                try? await clock.sleep(for: debounce, tolerance: nil)
                guard let self else { return }
                // Cancellation via generation guard: only the still-armed
                // generation fires; a stale fire after a race is a no-op.
                guard generation == self.generation else { return }
                self.pendingTask = nil
                self.reload(source)
            }
            return
        }

        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        reload(source)
    }
}
