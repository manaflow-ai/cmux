import Foundation

/// Periodically refreshes the list of Claude Code agent sessions shown in a
/// custom sidebar (the interpreter's top-level `agents` array).
///
/// The poller owns no process-spawning or executable-resolution logic itself —
/// that is the app's concern and is injected as the `fetch` closure, which is
/// expected to run `claude agents --json --all` off the main thread and return
/// parsed snapshots (see ``ClaudeAgentsSessionParser``). Keeping the subprocess
/// out of this UI package preserves the layering and makes the poller trivially
/// testable with a stub fetch.
///
/// Lifecycle is explicit: ``start()`` begins a single non-overlapping refresh
/// loop (each tick awaits the previous fetch before sleeping), and ``stop()``
/// cancels it. The owning view should start the poller when a custom sidebar
/// appears and stop it when it disappears, so no `claude` subprocess runs while
/// no custom sidebar is on screen. `sessions` is read on each ~1s sidebar tick;
/// because this type is not observable, updates are picked up by that tick
/// rather than by invalidating SwiftUI — intentionally, to avoid the
/// orthogonal-invalidation churn the sidebar list is sensitive to.
@MainActor
public final class ClaudeAgentsSessionPoller {
    /// The most recent successfully-fetched agent sessions. Empty until the
    /// first successful poll; a failed poll leaves the previous value in place.
    public private(set) var sessions: [CustomSidebarAgentSnapshot] = []

    private let interval: Duration
    private let fetch: @Sendable () async -> [CustomSidebarAgentSnapshot]?
    private var task: Task<Void, Never>?

    /// Creates a poller.
    ///
    /// - Parameters:
    ///   - interval: Delay between the end of one fetch and the start of the
    ///     next. Defaults to 3 seconds — frequent enough to feel live without
    ///     spawning `claude` too aggressively.
    ///   - fetch: Returns the current agent sessions, or `nil` on failure (in
    ///     which case the previous `sessions` value is kept). Must do its work
    ///     off the main thread.
    public nonisolated init(
        interval: Duration = .seconds(3),
        fetch: @escaping @Sendable () async -> [CustomSidebarAgentSnapshot]?
    ) {
        self.interval = interval
        self.fetch = fetch
    }

    /// Starts the refresh loop. No-op if already running.
    public func start() {
        guard task == nil else { return }
        let fetch = self.fetch
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let result = await fetch() {
                    self?.sessions = result
                }
                if Task.isCancelled { break }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Cancels the refresh loop. Safe to call when not running.
    public func stop() {
        task?.cancel()
        task = nil
    }
}
