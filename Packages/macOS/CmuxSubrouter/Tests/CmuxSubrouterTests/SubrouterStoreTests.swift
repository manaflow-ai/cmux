import Foundation
import Testing
@testable import CmuxSubrouter

/// The poll state machine: visibility gating, cadence selection, failure
/// backoff, idle-when-disabled, and idle-when-hidden — all on virtual time.
@MainActor
@Suite struct SubrouterStoreTests {
    /// Zero jitter so armed deadlines assert exactly.
    private static let tuning = SubrouterPollTuning(
        panelPollInterval: 20,
        backgroundPollInterval: 120,
        failureBackoffBase: 5,
        failureBackoffMax: 40,
        jitterFraction: 0,
        staleAfter: 30
    )

    private func makeStore(
        client: FakeSubrouterClient,
        clock: ManualSubrouterPollClock,
        switcher: FakeAccountSwitcher = FakeAccountSwitcher(),
        enabled: Bool = true
    ) -> SubrouterStore {
        SubrouterStore(
            client: client,
            switcher: switcher,
            clock: clock,
            configuration: SubrouterConfiguration(isEnabled: enabled, tuning: Self.tuning)
        )
    }

    private static func usageRow(id: String = "dev@example.com", active: Bool = true) -> SubrouterAccountUsageStatus {
        SubrouterAccountUsageStatus(id: id, provider: .codex, authChecked: true, authValid: true, isActive: active)
    }

    @Test func disabledStoreNeverPolls() async {
        let client = FakeSubrouterClient()
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock, enabled: false)

        store.setSurfaceVisible(.agentsPanel, true)
        store.refresh(reason: "test")
        await store.performFreshRefresh(reason: "test")

        #expect(await client.totalFetchCallCount == 0)
        #expect(await clock.recordedDurations.isEmpty)
        #expect(store.snapshot == .empty)
    }

    @Test func panelVisibilityTriggersRefreshAndArmsPanelCadence() async {
        let client = FakeSubrouterClient()
        await client.setUsageResult(.success([Self.usageRow()]))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()

        #expect(store.snapshot.daemonState == .healthy)
        #expect(store.snapshot.usageStatuses.count == 1)
        #expect(store.snapshot.lastUpdatedAt != nil)
        #expect(await clock.lastRecordedDuration == 20)
        #expect(await client.usageCallCount == 1)
        #expect(await client.sessionsCallCount == 1)
    }

    @Test func footerOnlyVisibilityArmsBackgroundCadence() async {
        let client = FakeSubrouterClient()
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.footerSwitcher, true)
        await clock.waitForSleeper()

        #expect(await clock.lastRecordedDuration == 120)
    }

    @Test func timerFiringRefreshesAgain() async {
        let client = FakeSubrouterClient()
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(await client.usageCallCount == 1)

        await clock.resumeNext()
        await clock.waitForSleeper()
        #expect(await client.usageCallCount == 2)
        _ = store
    }

    @Test func failuresBackOffExponentiallyAndCap() async {
        let client = FakeSubrouterClient()
        await client.setHealthResult(.failure(.unreachable(description: "connection refused")))
        await client.setUsageResult(.failure(.unreachable(description: "connection refused")))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(store.snapshot.daemonState == .unreachable(consecutiveFailures: 1))
        #expect(store.snapshot.lastErrorDescription == "connection refused")
        #expect(await clock.lastRecordedDuration == 5)

        await clock.resumeNext()
        await clock.waitForSleeper()
        #expect(store.snapshot.daemonState == .unreachable(consecutiveFailures: 2))
        #expect(await clock.lastRecordedDuration == 10)

        await clock.resumeNext()
        await clock.waitForSleeper()
        #expect(await clock.lastRecordedDuration == 20)

        await clock.resumeNext()
        await clock.waitForSleeper()
        #expect(await clock.lastRecordedDuration == 40)

        // Capped at failureBackoffMax.
        await clock.resumeNext()
        await clock.waitForSleeper()
        #expect(await clock.lastRecordedDuration == 40)
    }

    @Test func recoveryResetsBackoffToPanelCadence() async {
        let client = FakeSubrouterClient()
        await client.setHealthResult(.failure(.unreachable(description: "refused")))
        await client.setUsageResult(.failure(.unreachable(description: "refused")))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(await clock.lastRecordedDuration == 5)

        await client.setUsageResult(.success([Self.usageRow()]))
        await clock.resumeNext()
        await clock.waitForSleeper()

        #expect(store.snapshot.daemonState == .healthy)
        #expect(store.snapshot.lastErrorDescription == nil)
        #expect(await clock.lastRecordedDuration == 20)
    }

    @Test func transientFailuresWithDataKeepHealthyUntilGraceExhausted() async {
        let client = FakeSubrouterClient()
        await client.setUsageResult(.success([Self.usageRow()]))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(store.snapshot.daemonState == .healthy)

        // With data on screen, failures below the grace threshold keep the
        // healthy state (no scary banner) while recording the error.
        await client.setHealthResult(.failure(.unreachable(description: "timed out")))
        await client.setUsageResult(.failure(.unreachable(description: "timed out")))
        for failure in 1..<SubrouterStore.unreachableGraceFailures {
            await clock.resumeNext()
            await clock.waitForSleeper()
            #expect(store.snapshot.daemonState == .healthy, "failure \(failure)")
            #expect(store.snapshot.lastErrorDescription == "timed out")
            #expect(!store.snapshot.usageStatuses.isEmpty)
        }

        // The grace-exhausting failure finally flips the state.
        await clock.resumeNext()
        await clock.waitForSleeper()
        #expect(store.snapshot.daemonState
            == .unreachable(consecutiveFailures: SubrouterStore.unreachableGraceFailures))

        // Recovery goes straight back to healthy and clears the error.
        await client.setHealthResult(.success(true))
        await client.setUsageResult(.success([Self.usageRow()]))
        await clock.resumeNext()
        await clock.waitForSleeper()
        #expect(store.snapshot.daemonState == .healthy)
        #expect(store.snapshot.lastErrorDescription == nil)
    }

    @Test func sessionsAreCappedToMostRecentlyUpdated() {
        let base = Date(timeIntervalSince1970: 6_000_000)
        let sessions = (0..<(SubrouterStore.maxRetainedSessions + 40)).map { index in
            SubrouterSessionAssignment(
                agentType: "codex",
                sessionID: "s\(index)",
                accountID: "a",
                userEmail: nil,
                createdAt: base,
                updatedAt: base.addingTimeInterval(Double(index))
            )
        }
        let bounded = SubrouterStore.boundedSessions(sessions.shuffled())
        #expect(bounded.count == SubrouterStore.maxRetainedSessions)
        // The oldest 40 fell off; everything kept is newer than them.
        let keptIDs = Set(bounded.map(\.sessionID))
        for index in 0..<40 {
            #expect(!keptIDs.contains("s\(index)"))
        }
    }

    @Test func sessionsFailureKeepsFreshUsage() async {
        let client = FakeSubrouterClient()
        await client.setUsageResult(.success([Self.usageRow()]))
        await client.setSessionsResult(.failure(.httpStatus(code: 500, description: "")))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()

        // Sessions are ancillary: their failure must not discard freshly
        // fetched usage or flip the daemon state.
        #expect(store.snapshot.daemonState == .healthy)
        #expect(store.snapshot.usageStatuses.count == 1)
        #expect(store.snapshot.lastUpdatedAt != nil)
        #expect(store.snapshot.lastErrorDescription == "HTTP 500")
        // The usage response already proves reachability: no health probe,
        // no failure backoff.
        #expect(await client.healthCallCount == 0)
        #expect(await clock.lastRecordedDuration == 20)
    }

    @Test func dataFailureWithReachableDaemonNeverShowsUnreachable() async {
        let client = FakeSubrouterClient()
        // `/usage-status` fans out to provider APIs and can fail while the
        // daemon itself is up; the health probe is the reachability
        // authority, so even a cold first load must not show the
        // unreachable card (and its install hint).
        await client.setUsageResult(.failure(.unreachable(description: "timed out")))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(store.snapshot.daemonState == .healthy)
        #expect(store.snapshot.lastErrorDescription == "timed out")
        #expect(await client.healthCallCount == 1)
        // Backoff still applies so a struggling daemon is not hammered.
        #expect(await clock.lastRecordedDuration == 5)

        // Repeated data failures with a reachable daemon stay healthy even
        // past the unreachable grace threshold.
        for _ in 0..<SubrouterStore.unreachableGraceFailures {
            await clock.resumeNext()
            await clock.waitForSleeper()
        }
        #expect(store.snapshot.daemonState == .healthy)
    }

    @Test func hidingAllSurfacesGoesFullyIdle() async {
        let client = FakeSubrouterClient()
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        let callsWhileVisible = await client.usageCallCount

        store.setSurfaceVisible(.agentsPanel, false)
        // The parked deadline is cancelled and no new one is armed.
        await clock.waitForNoSleepers()
        #expect(await clock.parkedSleeperCount == 0)
        #expect(await client.usageCallCount == callsWhileVisible)
        // Existing data is kept for the next appearance.
        #expect(store.snapshot.daemonState == .healthy)
    }

    @Test func freshSnapshotSkipsRefreshOnReappearance() async {
        let client = FakeSubrouterClient()
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(await client.usageCallCount == 1)

        store.setSurfaceVisible(.agentsPanel, false)
        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        // Snapshot is younger than staleAfter: no second fetch, timer re-armed.
        #expect(await client.usageCallCount == 1)
    }

    @Test func disablingClearsSnapshotAndStopsPolling() async {
        let client = FakeSubrouterClient()
        await client.setUsageResult(.success([Self.usageRow()]))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(store.snapshot.usageStatuses.count == 1)

        store.updateConfiguration(SubrouterConfiguration(isEnabled: false, tuning: Self.tuning))
        await clock.waitForNoSleepers()
        #expect(store.snapshot == .empty)
        #expect(await clock.parkedSleeperCount == 0)
    }

    @Test func endpointChangeCancelsInFlightRefreshAndStartsFresh() async {
        let client = FakeSubrouterClient()
        await client.setUsageResult(.success([Self.usageRow()]))
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock)

        store.setSurfaceVisible(.agentsPanel, true)
        await clock.waitForSleeper()
        #expect(await client.usageCallCount == 1)

        // An endpoint change while a poll deadline is armed cancels it and
        // refreshes against the new endpoint immediately (the old refresh
        // must not survive to overwrite the reset state).
        let newEndpoint = SubrouterEndpoint(configurationString: "127.0.0.1:9999")!
        store.updateConfiguration(
            SubrouterConfiguration(isEnabled: true, endpoint: newEndpoint, tuning: Self.tuning)
        )
        // The old poll deadline is cancelled first, then the fresh refresh
        // against the new endpoint re-arms the timer.
        await clock.waitForNoSleepers()
        await clock.waitForSleeper()
        #expect(await client.usageCallCount == 2)
        #expect(await client.lastEndpoint == newEndpoint)
        #expect(store.snapshot.daemonState == .healthy)
    }

    @Test func enablingWhileVisibleRefreshesImmediately() async {
        let client = FakeSubrouterClient()
        let clock = ManualSubrouterPollClock()
        let store = makeStore(client: client, clock: clock, enabled: false)

        store.setSurfaceVisible(.agentsPanel, true)
        #expect(await client.totalFetchCallCount == 0)

        store.updateConfiguration(SubrouterConfiguration(isEnabled: true, tuning: Self.tuning))
        await clock.waitForSleeper()
        #expect(await client.usageCallCount == 1)
        #expect(store.snapshot.daemonState == .healthy)
    }

    @Test func snapshotDerivations() {
        let cookedWindow = SubrouterUsageWindow(name: "7d", usedPercent: 100)
        let snapshot = SubrouterSnapshot(
            daemonState: .healthy,
            usageStatuses: [
                SubrouterAccountUsageStatus(id: "b", provider: .claude, isActive: true, windows: [cookedWindow]),
                SubrouterAccountUsageStatus(id: "a", provider: .codex, isActive: true),
                SubrouterAccountUsageStatus(id: "c", provider: .codex),
            ],
            sessions: [
                SubrouterSessionAssignment(
                    agentType: "codex",
                    sessionID: "s1",
                    accountID: "a",
                    createdAt: Date(timeIntervalSince1970: 100),
                    updatedAt: Date(timeIntervalSince1970: 200)
                ),
            ]
        )
        #expect(snapshot.providers == [.codex, .claude])
        #expect(snapshot.accounts(for: .codex).map(\.id) == ["a", "c"])
        #expect(snapshot.activeAccount(for: .codex)?.id == "a")
        #expect(snapshot.activeAccount(for: .claude)?.id == "b")
        // Claude's active account is cooked → exactly one provider needs attention.
        #expect(snapshot.attentionCount == 1)
        #expect(snapshot.sessions(forAccountID: "a").count == 1)
    }
}
