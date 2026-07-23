public import Foundation
public import Observation

/// The single owner of cmux's subrouter state: it polls the daemon while a
/// subrouter UI surface is visible, projects results into an immutable
/// ``SubrouterSnapshot``, and sequences account switches (see
/// `SubrouterStore+Switching.swift`).
///
/// **Isolation.** `@MainActor @Observable`: every consumer (Agents panel,
/// footer switcher, socket handlers hopping to main) reads the snapshot on
/// the main actor, and `URLSession`'s async API never blocks the thread the
/// awaits run on.
///
/// **Polling is strictly gated** (the post-#8175 rule):
/// - master setting off → fully idle, snapshot cleared, zero requests;
/// - no visible surface → fully idle (existing data kept);
/// - Agents panel visible → ``SubrouterPollTuning/panelPollInterval``;
/// - footer switcher only → ``SubrouterPollTuning/backgroundPollInterval``;
/// - daemon unreachable → exponential backoff from
///   ``SubrouterPollTuning/failureBackoffBase`` capped at
///   ``SubrouterPollTuning/failureBackoffMax``, still only while visible.
///
/// All deadlines carry ±``SubrouterPollTuning/jitterFraction`` jitter and run
/// on the injected ``SubrouterPollClock`` so tests use virtual time.
@MainActor
@Observable
public final class SubrouterStore {
    // MARK: Observable state

    /// The current projection of daemon state, accounts, and sessions.
    public internal(set) var snapshot: SubrouterSnapshot = .empty
    /// The provider-scoped identity of an in-flight switch, or `nil`.
    /// Drives per-row progress UI; cleared when the switch settles.
    public internal(set) var pendingSwitch: SubrouterPendingSwitch?
    /// The most recent switch failure, or `nil`. Cleared when a new switch
    /// starts.
    public internal(set) var lastSwitchError: SubrouterSwitchError?

    // MARK: Dependencies

    @ObservationIgnored let client: any SubrouterClienting
    @ObservationIgnored let switcher: any SubrouterAccountSwitching
    @ObservationIgnored let clock: any SubrouterPollClock
    @ObservationIgnored let now: @Sendable () -> Date

    /// Re-resolves configuration inputs that live outside the store — sr's
    /// server registry — immediately before a switch, so the remote-server
    /// guard never evaluates a cache that predates an `sr server use` run
    /// inside a cmux terminal. Set once by the app runtime; awaited at the
    /// top of ``switchAccount(provider:accountID:)`` on every entrypoint
    /// (panel, footer popover, socket).
    @ObservationIgnored public var configurationPreflight: (@Sendable () async -> Void)?

    // MARK: Poll state (main-actor)

    /// Consecutive refresh failures tolerated before an existing snapshot's
    /// `daemonState` flips to unreachable. See `apply(_:)`.
    public static let unreachableGraceFailures = 3

    /// Cap on session assignments retained per snapshot. The daemon's
    /// sessions endpoint carries routing history that can grow for the
    /// life of a daemon; without a bound every poll would inflate snapshot
    /// memory and the per-render aggregation work downstream.
    public nonisolated static let maxRetainedSessions = 512

    @ObservationIgnored private var configurationStorage: SubrouterConfiguration
    @ObservationIgnored private(set) var visibleSurfaces: Set<SubrouterVisibleSurface> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var consecutiveFailureCount = 0
    @ObservationIgnored private let historyStorageURL: URL?
    /// The one-shot off-main load of the persisted history; kept so deinit
    /// cancels it and tests can await adoption deterministically.
    @ObservationIgnored private(set) var historyLoadTask: Task<Void, Never>?
    /// The tail of the serialized history-save chain: each save awaits the
    /// previous one so an older snapshot can never atomically replace a
    /// newer one on disk.
    @ObservationIgnored private var historySaveTask: Task<Void, Never>?

    /// Rolling usage samples per account window; the panel renders these as
    /// sparklines. Persisted to ``historyStorageURL`` when provided; starts
    /// empty and adopts the persisted file via an off-main load so the
    /// main-actor `init` never touches disk.
    public private(set) var usageHistory: SubrouterUsageHistory

    /// Creates the store.
    ///
    /// - Parameters:
    ///   - client: The daemon HTTP seam; tests inject a fake.
    ///   - switcher: The `sr` CLI seam; tests inject a fake.
    ///   - clock: The poll-deadline clock; tests inject virtual time.
    ///   - configuration: The initial configuration; defaults to disabled
    ///     until the app pushes real settings.
    ///   - now: The wall-clock source for snapshot timestamps and staleness.
    public init(
        client: any SubrouterClienting = SubrouterHTTPClient(),
        switcher: any SubrouterAccountSwitching = SubrouterCommandSwitcher(),
        clock: any SubrouterPollClock = SystemSubrouterPollClock(),
        configuration: SubrouterConfiguration = .disabled,
        historyStorageURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.switcher = switcher
        self.clock = clock
        self.configurationStorage = configuration
        self.historyStorageURL = historyStorageURL
        self.usageHistory = SubrouterUsageHistory()
        self.now = now
        if let historyStorageURL {
            // Read + decode off the main actor: init runs on main (app
            // launch or first socket verb) and the persisted file can reach
            // a few hundred KB at the retention caps.
            historyLoadTask = Task.detached(priority: .utility) { [weak self] in
                let loaded = SubrouterUsageHistory.load(from: historyStorageURL)
                guard loaded != SubrouterUsageHistory() else { return }
                await self?.adoptPersistedUsageHistory(loaded)
            }
        }
    }

    deinit {
        pollTask?.cancel()
        refreshTask?.cancel()
        historyLoadTask?.cancel()
        historySaveTask?.cancel()
    }

    /// Adopts the history loaded from disk. Merges under any samples a
    /// refresh recorded while the load was in flight, so losing that race
    /// never discards the persisted week of sparkline history.
    private func adoptPersistedUsageHistory(_ loaded: SubrouterUsageHistory) {
        usageHistory.merge(olderHistory: loaded)
    }

    // MARK: Configuration

    /// The active configuration. Update via ``updateConfiguration(_:)``.
    public var configuration: SubrouterConfiguration {
        configurationStorage
    }

    /// Applies a new configuration from settings.
    ///
    /// Disabling goes fully idle and clears the snapshot; enabling (or an
    /// endpoint change) resets failure state and refreshes immediately when
    /// a surface is visible.
    ///
    /// - Parameter newConfiguration: The configuration to apply.
    public func updateConfiguration(_ newConfiguration: SubrouterConfiguration) {
        let previous = configurationStorage
        configurationStorage = newConfiguration
        guard newConfiguration != previous else { return }
        if !newConfiguration.isEnabled {
            goIdle()
            snapshot = .empty
            return
        }
        if !previous.isEnabled || newConfiguration.endpoint != previous.endpoint {
            // Cancel any in-flight fetch first: a response from the previous
            // endpoint must not land after the reset, and a live refreshTask
            // would make the refresh below no-op.
            goIdle()
            snapshot.daemonState = .unknown
            if !visibleSurfaces.isEmpty {
                refresh(reason: "configuration")
            }
            return
        }
        updatePollTimer()
    }

    // MARK: Visibility gating

    /// Reports a subrouter UI surface appearing or disappearing.
    ///
    /// The poll cadence follows the visible set; an empty set stops polling
    /// entirely. A surface becoming visible refreshes immediately when the
    /// snapshot is missing or older than ``SubrouterPollTuning/staleAfter``.
    ///
    /// - Parameters:
    ///   - surface: The surface whose visibility changed.
    ///   - isVisible: Whether it is now visible.
    public func setSurfaceVisible(_ surface: SubrouterVisibleSurface, _ isVisible: Bool) {
        let previous = visibleSurfaces
        if isVisible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
        guard visibleSurfaces != previous else { return }
        guard configurationStorage.isEnabled else { return }
        if visibleSurfaces.isEmpty {
            goIdle()
            return
        }
        if isVisible, isSnapshotStale {
            refresh(reason: "visibility")
        } else {
            updatePollTimer()
        }
    }

    private var isSnapshotStale: Bool {
        guard let lastUpdatedAt = snapshot.lastUpdatedAt else { return true }
        return now().timeIntervalSince(lastUpdatedAt) > configurationStorage.tuning.staleAfter
    }

    // MARK: Refresh

    /// Starts a refresh unless one is already in flight. Gated only by the
    /// master setting: callers (timer, visibility, switch, socket verbs) are
    /// themselves the gate against background work.
    ///
    /// - Parameter reason: A short diagnostic tag.
    public func refresh(reason: String) {
        guard configurationStorage.isEnabled else { return }
        guard refreshTask == nil else { return }
        pollTask?.cancel()
        pollTask = nil
        let endpoint = configurationStorage.endpoint
        let client = client
        refreshTask = Task { @MainActor [weak self] in
            async let usageFetch = client.usageStatuses(endpoint: endpoint)
            async let sessionsFetch = client.sessions(endpoint: endpoint)
            let usageResult: Result<[SubrouterAccountUsageStatus], any Error>
            do { usageResult = .success(try await usageFetch) } catch { usageResult = .failure(error) }
            let sessionsResult: Result<[SubrouterSessionAssignment], any Error>
            do { sessionsResult = .success(try await sessionsFetch) } catch { sessionsResult = .failure(error) }

            let outcome: RefreshOutcome
            switch (usageResult, sessionsResult) {
            case (.success(let usage), .success(let sessions)):
                outcome = .success(usage: usage, sessions: sessions)
            case (.success(let usage), .failure(let error)):
                // Sessions are ancillary: a sessions timeout or bad row
                // must not discard freshly fetched account usage. The
                // usage response also proves the daemon is reachable.
                outcome = .partial(usage: usage, sessionsErrorDescription: Self.shortDescription(for: error))
            case (.failure(let error), _):
                outcome = await Self.failureOutcome(
                    description: Self.shortDescription(for: error),
                    client: client,
                    endpoint: endpoint
                )
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.apply(outcome)
            self.updatePollTimer()
        }
    }

    /// Awaits a refresh that starts after any in-flight one settles, so the
    /// returned snapshot reflects daemon state from after the call. Used by
    /// switches and the socket verbs.
    ///
    /// - Parameter reason: A short diagnostic tag.
    /// - Returns: The refreshed snapshot.
    @discardableResult
    public func performFreshRefresh(reason: String) async -> SubrouterSnapshot {
        guard configurationStorage.isEnabled else { return snapshot }
        while let inFlight = refreshTask {
            await inFlight.value
        }
        refresh(reason: reason)
        if let started = refreshTask {
            await started.value
        }
        return snapshot
    }

    private enum RefreshOutcome {
        case success(usage: [SubrouterAccountUsageStatus], sessions: [SubrouterSessionAssignment])
        case partial(usage: [SubrouterAccountUsageStatus], sessionsErrorDescription: String)
        case failure(description: String, daemonReachable: Bool)
    }

    /// A user-safe description for a refresh error. Unknown errors never
    /// carry raw dumps into user-facing state; the type name alone is safe
    /// and still diagnostic.
    private static func shortDescription(for error: any Error) -> String {
        if let clientError = error as? SubrouterClientError {
            return clientError.shortDescription
        }
        return "unexpected error (\(type(of: error)))"
    }

    /// Shapes a refresh failure. The data endpoints can fail while the
    /// daemon itself is fine — `/usage-status` fans out to provider APIs and
    /// can blow a timeout on a remote server — so the cheap health endpoint
    /// is the reachability authority: only its failure may render the
    /// "daemon unreachable" card and install hint.
    private static func failureOutcome(
        description: String,
        client: any SubrouterClienting,
        endpoint: SubrouterEndpoint
    ) async -> RefreshOutcome {
        let reachable = (try? await client.health(endpoint: endpoint)) ?? false
        return .failure(description: description, daemonReachable: reachable)
    }

    private func apply(_ outcome: RefreshOutcome) {
        switch outcome {
        case .success(let usage, let sessions):
            consecutiveFailureCount = 0
            snapshot = SubrouterSnapshot(
                daemonState: .healthy,
                usageStatuses: usage,
                sessions: Self.boundedSessions(sessions),
                lastUpdatedAt: now(),
                lastErrorDescription: nil
            )
            recordUsageHistory(usage)
        case .partial(let usage, let sessionsErrorDescription):
            consecutiveFailureCount = 0
            snapshot = SubrouterSnapshot(
                daemonState: .healthy,
                usageStatuses: usage,
                sessions: snapshot.sessions,
                lastUpdatedAt: now(),
                lastErrorDescription: sessionsErrorDescription
            )
            recordUsageHistory(usage)
        case .failure(let description, let daemonReachable):
            consecutiveFailureCount += 1
            if daemonReachable {
                // The daemon answered its health probe: the data fetch
                // failed (provider fan-out timeout, transient 5xx) but the
                // daemon is up, so the unreachable card and install hint
                // must not appear. Backoff still applies via the failure
                // count so a struggling daemon is not hammered.
                snapshot.daemonState = .healthy
            } else if snapshot.usageStatuses.isEmpty
                || consecutiveFailureCount >= Self.unreachableGraceFailures {
                // One flaky poll must not slam an "unreachable" banner over
                // a panel showing perfectly good data from seconds ago.
                // With data on screen the state flips only after a few
                // consecutive failures; with nothing to stand on it flips
                // immediately so onboarding still fails fast.
                snapshot.daemonState = .unreachable(consecutiveFailures: consecutiveFailureCount)
            }
            snapshot.lastErrorDescription = description
        }
    }

    /// Keeps the ``maxRetainedSessions`` most recently updated assignments,
    /// preserving the daemon's ordering for the kept subset.
    nonisolated static func boundedSessions(
        _ sessions: [SubrouterSessionAssignment]
    ) -> [SubrouterSessionAssignment] {
        guard sessions.count > maxRetainedSessions else { return sessions }
        let cutoff = sessions.map(\.updatedAt).sorted(by: >)[maxRetainedSessions - 1]
        var kept: [SubrouterSessionAssignment] = []
        kept.reserveCapacity(maxRetainedSessions)
        for session in sessions where session.updatedAt >= cutoff {
            kept.append(session)
            if kept.count == maxRetainedSessions { break }
        }
        return kept
    }

    /// Records freshly fetched usage into the rolling history and persists
    /// it off-main when anything changed. Saves chain on the previous one
    /// so writes land in order — overlapping detached saves could commit
    /// an older snapshot last.
    private func recordUsageHistory(_ usage: [SubrouterAccountUsageStatus]) {
        guard usageHistory.record(usageStatuses: usage, now: now()),
              let historyStorageURL else { return }
        let history = usageHistory
        let previousSave = historySaveTask
        historySaveTask = Task.detached(priority: .utility) {
            await previousSave?.value
            history.save(to: historyStorageURL)
        }
    }

    // MARK: Poll timer

    private func goIdle() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        consecutiveFailureCount = 0
    }

    private func updatePollTimer() {
        pollTask?.cancel()
        pollTask = nil
        guard configurationStorage.isEnabled,
              !visibleSurfaces.isEmpty,
              refreshTask == nil else {
            return
        }
        let delay = nextPollDelay()
        let clock = clock
        pollTask = Task { @MainActor [weak self] in
            // Bounded, cancellable poll deadline on the injected clock;
            // re-arming cancels the previous task.
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refresh(reason: "timer")
        }
    }

    /// The next poll delay from the current cadence/backoff state, jittered.
    /// Internal so tests can assert the schedule directly.
    func nextPollDelay() -> TimeInterval {
        let tuning = configurationStorage.tuning
        let base: TimeInterval
        if consecutiveFailureCount > 0 {
            let exponent = min(consecutiveFailureCount - 1, 10)
            base = min(
                tuning.failureBackoffBase * pow(2, Double(exponent)),
                tuning.failureBackoffMax
            )
        } else if visibleSurfaces.contains(.agentsPanel) {
            base = tuning.panelPollInterval
        } else {
            base = tuning.backgroundPollInterval
        }
        return Self.jittered(base, fraction: tuning.jitterFraction)
    }

    /// Applies ±`fraction` random jitter to a base interval.
    nonisolated static func jittered(_ base: TimeInterval, fraction: Double) -> TimeInterval {
        guard fraction > 0 else { return base }
        let jitter = base * fraction
        return max(0.25, base + Double.random(in: -jitter...jitter))
    }
}
