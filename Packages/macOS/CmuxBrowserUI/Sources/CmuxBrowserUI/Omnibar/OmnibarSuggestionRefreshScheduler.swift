import Foundation
import Observation

/// Debounces omnibar suggestion refreshes into a single coalesced stream.
///
/// Edits to the address bar call ``scheduleRefresh()`` on every keystroke; the
/// scheduler waits out a short debounce window and then yields one generation
/// token on ``refreshStream``. The consumer drains that stream and runs a
/// refresh only for the newest generation, so a burst of keystrokes collapses
/// into one suggestion fetch. ``cancelPendingRefresh()`` bumps the generation so
/// any in-flight or queued refresh is discarded.
@MainActor
@Observable
final class OmnibarSuggestionRefreshScheduler {
    let refreshStream: AsyncStream<UInt64>

    @ObservationIgnored private var refreshContinuation: AsyncStream<UInt64>.Continuation
    @ObservationIgnored private var debounceDelay: Duration
    @ObservationIgnored private var clock: any OmnibarSuggestionRefreshClock
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?

    init(
        debounceDelay: Duration = .milliseconds(80),
        clock: any OmnibarSuggestionRefreshClock = ContinuousOmnibarSuggestionRefreshClock()
    ) {
        self.debounceDelay = debounceDelay
        self.clock = clock
        let refreshPipe = AsyncStream<UInt64>.makeStream()
        refreshStream = refreshPipe.stream
        refreshContinuation = refreshPipe.continuation
    }

    func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let debounceDelay = debounceDelay
        let clock = clock
        pendingRefreshTask = Task { @MainActor [weak self, generation, debounceDelay, clock] in
            guard !Task.isCancelled else { return }
            do {
                try await clock.sleep(for: debounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard refreshGeneration == generation else { return }
            pendingRefreshTask = nil
            refreshContinuation.yield(generation)
        }
    }

    func cancelPendingRefresh() {
        refreshGeneration &+= 1
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
    }

    func shouldProcessRefresh(_ generation: UInt64) -> Bool {
        refreshGeneration == generation
    }
}

/// Awaitable delay abstraction the refresh scheduler debounces against,
/// injectable so tests can drive the debounce window deterministically.
protocol OmnibarSuggestionRefreshClock: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Production ``OmnibarSuggestionRefreshClock`` backed by ``ContinuousClock``.
struct ContinuousOmnibarSuggestionRefreshClock: OmnibarSuggestionRefreshClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
