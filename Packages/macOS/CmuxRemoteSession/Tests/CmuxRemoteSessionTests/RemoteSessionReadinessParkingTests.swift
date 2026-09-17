import CmuxCore
import CmuxFoundation
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/12813:
/// direct SSH and the ControlMaster probe succeed, but the daemon, reverse
/// relay, or proxy never becomes ready. The session must reach a terminal
/// state in bounded time and must release every `ssh-pty-attach --wait`
/// parked on it with the same actionable detail the sidebar shows, instead of
/// leaving each attach to time out and retry against a session that gave up.
@Suite("Remote session readiness parking")
struct RemoteSessionReadinessParkingTests {
    private static let readinessDeadlineMilliseconds = 60_000

    @Test(
        "A bootstrap that gives up releases the attach already waiting for readiness",
        .timeLimit(.minutes(1))
    )
    func parkedBootstrapReleasesWaitingAttach() async throws {
        let host = ReadinessRecordingHost()
        let fixture = try await Self.makeCoordinator(
            host: host,
            runner: ReadinessScriptedProcessRunner(daemon: .missing),
            clock: ManualBrokerClock()
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp() }

        let waitingAttach = LockedResult<RemotePTYBridgeServer.Endpoint>()
        coordinator.queue.sync {
            coordinator.pendingPTYBridgeStarts[UUID()] = PendingPTYBridgeStart(
                sessionID: "ssh-workspace-surface",
                lifecycleID: "lifecycle",
                attachmentID: "surface",
                command: nil,
                requireExisting: false,
                isCancelled: { waitingAttach.hasValue },
                completion: { _ = waitingAttach.setIfEmpty($0) }
            )
        }

        // Three identical bootstrap failures exhaust the retry policy.
        for _ in 0..<3 {
            coordinator.queue.sync { coordinator.beginConnectionAttemptLocked() }
        }

        let parked = try #require(await host.firstPublication(of: .suspended))
        let parkedDetail = try #require(parked.detail)
        #expect(!parkedDetail.isEmpty)
        let released = try #require(
            waitingAttach.current,
            "a parked session must release the attach waiting on it"
        )
        #expect(throws: (any Error).self) { try released.get() }
        #expect(Self.failureDescription(of: released) == parkedDetail)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test(
        "An attach that arrives after the session parked fails at once with the parked detail",
        .timeLimit(.minutes(1))
    )
    func attachAgainstParkedSessionFailsImmediately() async throws {
        let host = ReadinessRecordingHost()
        let fixture = try await Self.makeCoordinator(
            host: host,
            runner: ReadinessScriptedProcessRunner(daemon: .missing),
            clock: ManualBrokerClock()
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp() }

        for _ in 0..<3 {
            coordinator.queue.sync { coordinator.beginConnectionAttemptLocked() }
        }
        let parked = try #require(await host.firstPublication(of: .suspended))
        let parkedDetail = try #require(parked.detail)

        // The wrapper's retry re-attaches with `--wait`. Nothing can make a
        // parked session ready, so parking this request until its timeout is
        // the hang; it must be refused with the reason instead.
        let outcome = Result {
            try coordinator.startPTYBridge(
                sessionID: "ssh-workspace-surface",
                lifecycleID: "lifecycle",
                attachmentID: "surface",
                command: nil,
                requireExisting: true,
                waitForReady: true,
                timeout: 5
            )
        }
        // The timeout path reports "timed out waiting for remote PTY
        // operation", so matching the parked detail proves it was not taken.
        #expect(throws: (any Error).self) { try outcome.get() }
        #expect(Self.failureDescription(of: outcome) == parkedDetail)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test(
        "A reverse relay that never becomes ready parks the session in bounded time",
        .timeLimit(.minutes(1))
    )
    func relayNeverReadyParksSession() async throws {
        let host = ReadinessRecordingHost()
        let launcher = RecordingReverseRelayLauncher()
        let clock = ManualBrokerClock()
        let fixture = try await Self.makeCoordinator(
            host: host,
            runner: ReadinessScriptedProcessRunner(
                daemon: .installed(capabilities: Self.requiredCapabilities)
            ),
            reverseRelayLauncher: launcher,
            clock: clock
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp() }

        let waitingAttach = LockedResult<RemotePTYBridgeServer.Endpoint>()
        coordinator.queue.sync {
            coordinator.pendingPTYBridgeStarts[UUID()] = PendingPTYBridgeStart(
                sessionID: "ssh-workspace-surface",
                lifecycleID: "lifecycle",
                attachmentID: "surface",
                command: nil,
                requireExisting: false,
                isCancelled: { waitingAttach.hasValue },
                completion: { _ = waitingAttach.setIfEmpty($0) }
            )
            coordinator.beginConnectionAttemptLocked()
        }

        // The daemon answered hello, so readiness now depends only on the
        // asynchronous relay and proxy phases: that wait carries a deadline.
        let deadline = await Self.value(within: .seconds(10)) { await clock.nextRequestedDelay() }
        try #require(
            deadline == Self.readinessDeadlineMilliseconds,
            "the readiness seek after a daemon hello must carry a deadline"
        )
        #expect(launcher.launchCount == 1)

        // The standalone relay dies without ever reporting its forward; the
        // supervisor keeps restarting it, which on its own never terminates.
        launcher.emitTermination(detail: "remote port forwarding failed")
        #expect(await Self.value(within: .seconds(10)) { await clock.nextRequestedDelay() } == 2_000)

        await clock.resumeNextSleep()
        let parked = try #require(await host.firstPublication(of: .suspended))
        let parkedDetail = try #require(parked.detail)
        #expect(!parkedDetail.isEmpty)
        // Parking publishes and then releases its waiters inside one block on
        // the coordinator queue; the publication alone does not mean that
        // block has finished.
        coordinator.queue.sync {}
        let released = try #require(waitingAttach.current)
        #expect(Self.failureDescription(of: released) == parkedDetail)
        // Parking owns the transport: the relay restart loop must be over.
        #expect(coordinator.queue.sync {
            coordinator.reverseRelayRestartToken == nil &&
                coordinator.reverseRelayProcess == nil &&
                !coordinator.daemonReady
        })

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test(
        "A proxy that never becomes ready parks the session in bounded time",
        .timeLimit(.minutes(1))
    )
    func proxyNeverReadyParksSession() async throws {
        let host = ReadinessRecordingHost()
        let clock = ManualBrokerClock()
        let fixture = try await Self.makeCoordinator(
            host: host,
            runner: ReadinessScriptedProcessRunner(
                daemon: .installed(capabilities: Self.requiredCapabilities)
            ),
            proxyBroker: RemoteProxyBroker(
                tunnelProvider: NeverReadyProxyTunnelProvider(),
                clock: clock
            ),
            relayPort: nil,
            clock: clock
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp() }

        coordinator.queue.sync { coordinator.beginConnectionAttemptLocked() }

        // The broker's own restart backoff and the session's readiness
        // deadline are requested by independent tasks, in either order.
        let requested = [
            await Self.value(within: .seconds(10)) { await clock.nextRequestedDelay() },
            await Self.value(within: .seconds(10)) { await clock.nextRequestedDelay() },
        ]
        try #require(
            Set(requested) == [Self.readinessDeadlineMilliseconds, 3_000],
            "the readiness seek after a daemon hello must carry a deadline"
        )

        await clock.resumeNextSleep()
        await clock.resumeNextSleep()
        let parked = try #require(await host.firstPublication(of: .suspended))
        #expect(parked.detail?.isEmpty == false)
        coordinator.queue.sync {}
        #expect(coordinator.queue.sync {
            coordinator.proxyLease == nil && !coordinator.daemonReady
        })

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test(
        "Reaching readiness ends the seek, so a healthy session can never be parked by a stale deadline",
        .timeLimit(.minutes(1))
    )
    func readinessDisarmsDeadline() async throws {
        let host = ReadinessRecordingHost()
        let clock = ManualBrokerClock()
        let fixture = try await Self.makeCoordinator(
            host: host,
            runner: ReadinessScriptedProcessRunner(
                daemon: .installed(capabilities: Self.requiredCapabilities)
            ),
            proxyBroker: RemoteProxyBroker(
                tunnelProvider: IntentionalCleanupTestTunnelProvider(),
                clock: clock
            ),
            relayPort: nil,
            clock: clock
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp() }

        coordinator.queue.sync { coordinator.beginConnectionAttemptLocked() }
        let deadline = await Self.value(within: .seconds(10)) { await clock.nextRequestedDelay() }
        try #require(deadline == Self.readinessDeadlineMilliseconds)
        _ = try #require(await host.firstPublication(of: .connected))

        // The wakeup of a disarmed deadline is dropped by its token guard, so
        // resuming the clock afterwards cannot park the session.
        #expect(coordinator.queue.sync {
            coordinator.readinessDeadlineToken == nil &&
                coordinator.parkedState == nil &&
                coordinator.canStartPTYBridgeLocked
        })

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A later loss of readiness starts a fresh seek with its own deadline")
    func deadlineIsArmedOncePerSeek() async throws {
        let fixture = try await Self.makeCoordinator(
            host: ReadinessRecordingHost(),
            runner: ReadinessScriptedProcessRunner(daemon: .missing),
            clock: ManualBrokerClock()
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp() }

        let tokens = coordinator.queue.sync { () -> [UUID?] in
            coordinator.proxyConnectionDesired = true
            coordinator.armReadinessDeadlineLocked()
            let first = coordinator.readinessDeadlineToken
            // A second hello inside the same seek (an escalate-and-rebootstrap
            // cycle) must not push the deadline out.
            coordinator.armReadinessDeadlineLocked()
            let second = coordinator.readinessDeadlineToken
            coordinator.endReadinessSeekLocked()
            coordinator.armReadinessDeadlineLocked()
            return [first, second, coordinator.readinessDeadlineToken]
        }
        #expect(tokens[0] != nil)
        #expect(tokens[0] == tokens[1])
        #expect(tokens[2] != nil && tokens[2] != tokens[0])

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("An explicitly closed generation ends cleanly even when its session is parked")
    func explicitCleanupOutranksTheParkedVerdict() async throws {
        let provider = IntentionalCleanupTestTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider)
        let fixture = try await Self.makeCoordinator(
            host: ReadinessRecordingHost(),
            runner: ReadinessScriptedProcessRunner(daemon: .missing),
            proxyBroker: broker,
            relayPort: nil,
            clock: ManualBrokerClock()
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp(); provider.tunnel.stop() }
        let lease = broker.acquire(
            configuration: coordinator.configuration,
            remotePath: "/remote/cmuxd"
        ) { _ in }
        coordinator.queue.sync {
            coordinator.proxyLease = lease
            coordinator.proxyEndpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 42_424)
            coordinator.daemonReady = true
        }

        // The user closes one session; a second generation stays active.
        _ = try coordinator.startPTYBridge(
            sessionID: "closed-session",
            lifecycleID: "closed-generation",
            attachmentID: "surface-a",
            command: nil,
            requireExisting: false
        )
        try coordinator.closePTYSession(sessionID: "closed-session")

        // Then the session loses readiness and parks, keeping its broker entry.
        coordinator.queue.sync {
            coordinator.daemonReady = false
            coordinator.parkedState = RemoteSessionParkedState(
                cause: .readinessTimedOut,
                detail: "parked for test"
            )
        }

        #expect(throws: RemotePTYLifecycleError.intentionallyClosed) {
            try coordinator.startPTYBridge(
                sessionID: "closed-session",
                lifecycleID: "closed-generation",
                attachmentID: "surface-a",
                command: nil,
                requireExisting: true,
                waitForReady: true,
                timeout: 5
            )
        }
        #expect(throws: RemoteSessionParkedError(detail: "parked for test")) {
            try coordinator.startPTYBridge(
                sessionID: "open-session",
                lifecycleID: "open-generation",
                attachmentID: "surface-b",
                command: nil,
                requireExisting: true,
                waitForReady: true,
                timeout: 5
            )
        }

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A managed Cloud VM session, whose broker redials while the machine wakes, carries no deadline")
    func cloudVMSessionsAreNotDeadlined() async throws {
        let fixture = try await Self.makeCoordinator(
            host: ReadinessRecordingHost(),
            runner: ReadinessScriptedProcessRunner(daemon: .missing),
            relayPort: nil,
            skipDaemonBootstrap: true,
            clock: ManualBrokerClock()
        )
        let coordinator = fixture.coordinator
        defer { fixture.cleanUp() }

        let token = coordinator.queue.sync { () -> UUID? in
            coordinator.proxyConnectionDesired = true
            coordinator.armReadinessDeadlineLocked()
            return coordinator.readinessDeadlineToken
        }
        #expect(token == nil)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }
}
