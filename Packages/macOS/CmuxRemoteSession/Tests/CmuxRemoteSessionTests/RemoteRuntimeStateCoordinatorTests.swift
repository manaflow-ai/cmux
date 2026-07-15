import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote runtime state coordinator", .serialized)
struct RemoteRuntimeStateCoordinatorTests {
    @Test("keeps the latest snapshot queued during server document publication")
    func keepsLatestSnapshotDuringDocumentPublication() async throws {
        let gate = RuntimeStatePublicationGate()
        let fixture = Self.fixture(host: RuntimeStateRecordingHost(documentGate: gate))
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"server"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        Self.beginSynchronization(fixture)
        await gate.waitUntilStarted()

        let latestState = Data(#"{"title":"latest-local"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: latestState,
            baseRevision: 7
        )
        fixture.coordinator.queue.sync {}
        await gate.release()
        await Self.drainRuntimeStatePublication(fixture)

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 8)
        #expect(stored.state == latestState)
        #expect(fixture.host.revisions == [8])
    }

    @Test("rebases the latest snapshot queued during revision publication")
    func rebasesLatestSnapshotDuringRevisionPublication() async throws {
        let gate = RuntimeStatePublicationGate()
        let fixture = Self.fixture(host: RuntimeStateRecordingHost(revisionGate: gate))
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"server"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"first-local"}"#.utf8),
            baseRevision: 7
        )
        await gate.waitUntilStarted()

        let latestState = Data(#"{"title":"latest-local"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: latestState,
            baseRevision: 7
        )
        fixture.coordinator.queue.sync {}
        await gate.release()
        await Self.drainRuntimeStatePublication(fixture)

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 9)
        #expect(stored.state == latestState)
        #expect(fixture.host.revisions == [8, 9])
    }

    @Test("does not complete synchronization when the host rejects a document")
    func rejectedDocumentRemainsUnsynchronized() async {
        let fixture = Self.fixture(host: RuntimeStateRecordingHost(acceptsDocuments: false))
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"unsupported"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))

        await Self.synchronize(fixture)

        #expect(!fixture.coordinator.runtimeStateSynchronized)
        #expect(!fixture.coordinator.hasCompletedInitialRuntimeStateSynchronization)
    }

    @Test("does not remain synchronized when the host rejects a committed revision")
    func rejectedRevisionRemainsUnsynchronized() async throws {
        let fixture = Self.fixture(host: RuntimeStateRecordingHost(acceptsRevisions: false))
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"server"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"local"}"#.utf8),
            baseRevision: 7
        )
        await Self.drainRuntimeStatePublication(fixture)

        #expect(!fixture.coordinator.runtimeStateSynchronized)
        #expect(fixture.coordinator.hasCompletedInitialRuntimeStateSynchronization)
        #expect(fixture.host.revisions == [8])
        #expect(try fixture.provider.tunnel.getRuntimeState()?.revision == 8)
    }

    @Test("server state wins over a snapshot queued before the initial fetch")
    func serverWinsInitialSynchronization() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        let serverState = Data(#"{"title":"server"}"#.utf8)
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: serverState,
            ptySessions: Data("[]".utf8)
        ))
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"stale-local"}"#.utf8)
        )
        fixture.coordinator.queue.sync {}

        await Self.synchronize(fixture)

        #expect(fixture.host.documents.map(\.revision) == [7])
        #expect(fixture.host.revisions.isEmpty)
        let storedState = try fixture.provider.tunnel.getRuntimeState()?.state
        #expect(storedState == serverState)
    }

    @Test("an empty server is seeded from the queued workspace snapshot")
    func emptyServerIsSeeded() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        let localState = Data(#"{"title":"local-seed"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(schemaVersion: 1, state: localState)
        fixture.coordinator.queue.sync {}

        await Self.synchronize(fixture)

        #expect(fixture.host.documents.isEmpty)
        #expect(fixture.host.revisions == [0, 1])
        let storedState = try fixture.provider.tunnel.getRuntimeState()?.state
        #expect(storedState == localState)
    }

    @Test("a later snapshot retries a transient initial fetch failure before uploading")
    func autosaveRetriesInitialFetchFailure() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.failNextRuntimeStateGet()

        await Self.synchronize(fixture)
        #expect(!fixture.coordinator.runtimeStateSynchronized)

        let localState = Data(#"{"title":"retry-seed"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(schemaVersion: 1, state: localState)
        await Self.drainRuntimeStatePublication(fixture)

        #expect(fixture.coordinator.runtimeStateSynchronized)
        #expect(fixture.host.documents.isEmpty)
        #expect(fixture.host.revisions == [0, 1])
        let storedState = try fixture.provider.tunnel.getRuntimeState()?.state
        #expect(storedState == localState)
    }

    @Test("retries an initial fetch failure without waiting for an autosave")
    func retriesInitialFetchFailureWhileIdle() async {
        let clock = RuntimeStateRetryClock()
        let publicationGate = RuntimeStatePublicationGate()
        let fixture = Self.fixture(
            host: RuntimeStateRecordingHost(documentGate: publicationGate),
            clock: clock
        )
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"server"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        fixture.provider.tunnel.failNextRuntimeStateGet()

        Self.beginSynchronization(fixture)

        let retryScheduled = await Self.wait(
            for: clock.sleepScheduled,
            timeout: 1
        )
        #expect(retryScheduled == .success)
        guard retryScheduled == .success else { return }
        clock.advance()
        await publicationGate.waitUntilStarted()
        await publicationGate.release()
        await Self.drainRuntimeStatePublication(fixture)

        #expect(fixture.coordinator.runtimeStateSynchronized)
        #expect(fixture.host.documents.map(\.revision) == [7])
    }

    @Test("retries a transient put failure without waiting for another edit")
    func retriesPutFailureWhileIdle() async throws {
        let clock = RuntimeStateRetryClock()
        let revisionGate = RuntimeStatePublicationGate()
        let fixture = Self.fixture(
            host: RuntimeStateRecordingHost(revisionGate: revisionGate),
            clock: clock
        )
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"server"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)
        fixture.provider.tunnel.failNextRuntimeStatePut()

        let localState = Data(#"{"title":"local"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: localState,
            baseRevision: 7
        )
        fixture.coordinator.queue.sync {}

        let retryScheduled = await Self.wait(
            for: clock.sleepScheduled,
            timeout: 1
        )
        #expect(retryScheduled == .success)
        guard retryScheduled == .success else { return }
        clock.advance()
        await revisionGate.waitUntilStarted()
        await revisionGate.release()
        await Self.drainRuntimeStatePublication(fixture)

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 8)
        #expect(stored.state == localState)
        #expect(fixture.coordinator.runtimeStateSynchronized)
    }

    @Test("keeps the coordinator queue responsive while fetching runtime state")
    func fetchDoesNotBlockCoordinatorQueue() async {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        let fetchStarted = DispatchSemaphore(value: 0)
        let releaseFetch = DispatchSemaphore(value: 0)
        defer { releaseFetch.signal() }
        fixture.provider.tunnel.blockNextRuntimeStateGet(
            started: fetchStarted,
            release: releaseFetch
        )

        Self.beginSynchronizationAsynchronously(fixture)
        let started = await Self.wait(for: fetchStarted, timeout: 1)
        #expect(started == .success)
        guard started == .success else { return }

        let queueReached = DispatchSemaphore(value: 0)
        fixture.coordinator.queue.async {
            queueReached.signal()
        }
        let responsive = await Self.wait(for: queueReached, timeout: 0.25)
        #expect(responsive == .success)

        releaseFetch.signal()
        await Self.drainRuntimeStatePublication(fixture)
    }

    @Test("keeps the coordinator queue responsive while uploading runtime state")
    func putDoesNotBlockCoordinatorQueue() async {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"server"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        let putStarted = DispatchSemaphore(value: 0)
        let releasePut = DispatchSemaphore(value: 0)
        defer { releasePut.signal() }
        fixture.provider.tunnel.blockNextRuntimeStatePut(
            started: putStarted,
            release: releasePut
        )
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"local"}"#.utf8),
            baseRevision: 7
        )
        let started = await Self.wait(for: putStarted, timeout: 1)
        #expect(started == .success)
        guard started == .success else { return }

        let queueReached = DispatchSemaphore(value: 0)
        fixture.coordinator.queue.async {
            queueReached.signal()
        }
        let responsive = await Self.wait(for: queueReached, timeout: 0.25)
        #expect(responsive == .success)

        releasePut.signal()
        await Self.drainRuntimeStatePublication(fixture)
    }

    @Test("waits for the final runtime upload before finishing")
    func finishWaitsForFinalRuntimeUpload() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"server"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        let putStarted = DispatchSemaphore(value: 0)
        let releasePut = DispatchSemaphore(value: 0)
        defer { releasePut.signal() }
        fixture.provider.tunnel.blockNextRuntimeStatePut(
            started: putStarted,
            release: releasePut
        )
        let finalState = Data(#"{"title":"final"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: finalState,
            baseRevision: 7
        )
        let started = await Self.wait(for: putStarted, timeout: 1)
        #expect(started == .success)
        guard started == .success else { return }

        let finishCompleted = DispatchSemaphore(value: 0)
        let coordinator = fixture.coordinator
        let finish = Task {
            let succeeded = await coordinator.finishPendingRuntimeStateWork()
            finishCompleted.signal()
            return succeeded
        }
        let completedBeforePut = await Self.wait(for: finishCompleted, timeout: 0.25)
        #expect(completedBeforePut == .timedOut)

        releasePut.signal()
        let succeeded = await finish.value
        await Self.drainRuntimeStatePublication(fixture)
        #expect(succeeded)
        #expect(try fixture.provider.tunnel.getRuntimeState()?.state == finalState)
    }

    @Test("suspends retries after five failures until a new edit")
    func suspendsRetriesUntilNewEdit() async throws {
        let clock = RuntimeStateRetryClock()
        let fixture = Self.fixture(clock: clock)
        defer { fixture.stop() }
        fixture.provider.tunnel.failNextRuntimeStateGets(7)

        Self.beginSynchronization(fixture)
        for _ in 0..<5 {
            let scheduled = await Self.wait(for: clock.sleepScheduled, timeout: 1)
            #expect(scheduled == .success)
            guard scheduled == .success else { return }
            clock.advance()
        }

        let unexpectedRetry = await Self.wait(for: clock.sleepScheduled, timeout: 0.25)
        #expect(unexpectedRetry == .timedOut)

        fixture.provider.tunnel.clearRuntimeStateGetFailures()
        clock.advance()
        let localState = Data(#"{"title":"resume"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(schemaVersion: 1, state: localState)
        await Self.drainRuntimeStatePublication(fixture)

        #expect(fixture.coordinator.runtimeStateSynchronized)
        #expect(try fixture.provider.tunnel.getRuntimeState()?.state == localState)
    }

    @Test("applies authoritative state committed by another connected client")
    func appliesConnectedClientUpdate() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"initial"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        Self.connectThroughProductionProxy(fixture)
        await Self.drainRuntimeStatePublication(fixture)

        let updated = RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 8,
            updatedAtUnixMilliseconds: 2,
            state: Data(#"{"title":"other-client"}"#.utf8),
            ptySessions: Data("[]".utf8)
        )
        fixture.provider.tunnel.publishRuntimeState(updated)
        fixture.coordinator.queue.sync {}
        await Self.drainRuntimeStatePublication(fixture)

        #expect(fixture.host.documents.map(\.revision) == [7, 8])
        #expect(fixture.coordinator.lastKnownRuntimeStateRevision == 8)
        #expect(fixture.coordinator.runtimeStateSynchronized)
    }

    @Test("applies the latest connected-client update queued during host publication")
    func appliesConnectedClientUpdateDuringDocumentPublication() async throws {
        let gate = RuntimeStatePublicationGate()
        let fixture = Self.fixture(host: RuntimeStateRecordingHost(documentGate: gate))
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"initial"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        Self.connectThroughProductionProxy(fixture)
        await gate.waitUntilStarted()

        fixture.provider.tunnel.publishRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 8,
            updatedAtUnixMilliseconds: 2,
            state: Data(#"{"title":"other-client"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        fixture.coordinator.queue.sync {}
        await gate.release()
        await Self.drainRuntimeStatePublication(fixture)

        #expect(fixture.host.documents.map(\.revision) == [7, 8])
        #expect(fixture.coordinator.lastKnownRuntimeStateRevision == 8)
        #expect(fixture.coordinator.runtimeStateSynchronized)
    }

    @Test("server update wins while a local revision acknowledgement is publishing")
    func connectedClientUpdateWinsDuringRevisionPublication() async throws {
        let gate = RuntimeStatePublicationGate()
        let fixture = Self.fixture(host: RuntimeStateRecordingHost(revisionGate: gate))
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"initial"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        Self.connectThroughProductionProxy(fixture)
        await Self.drainRuntimeStatePublication(fixture)

        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"local"}"#.utf8),
            baseRevision: 7
        )
        await gate.waitUntilStarted()
        fixture.provider.tunnel.publishRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 9,
            updatedAtUnixMilliseconds: 3,
            state: Data(#"{"title":"other-client"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        fixture.coordinator.queue.sync {}
        await gate.release()
        await Self.drainRuntimeStatePublication(fixture)

        #expect(fixture.host.documents.map(\.revision) == [7, 9])
        #expect(fixture.host.revisions == [8])
        #expect(fixture.coordinator.lastKnownRuntimeStateRevision == 9)
        #expect(fixture.coordinator.runtimeStateSynchronized)
    }

    @Test("a reconnect uploads local edits when the server revision has not advanced")
    func reconnectPreservesPendingLocalEdit() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        let serverState = Data(#"{"title":"server"}"#.utf8)
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: serverState,
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        fixture.coordinator.queue.sync {
            fixture.coordinator.proxyLease = nil
            fixture.coordinator.runtimeStateSynchronized = false
        }
        let offlineEdit = Data(#"{"title":"offline edit"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: offlineEdit,
            baseRevision: 7
        )
        fixture.coordinator.queue.sync {}

        await Self.synchronize(fixture)

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 8)
        #expect(stored.state == offlineEdit)
        #expect(fixture.host.documents.map(\.revision) == [7])
        #expect(fixture.host.revisions == [8])
    }

    @Test("a snapshot captured before initial restore cannot overwrite fetched state")
    func staleInitialCaptureIsDiscarded() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        let serverState = Data(#"{"title":"server"}"#.utf8)
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: serverState,
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"stale capture"}"#.utf8),
            baseRevision: 0
        )
        fixture.coordinator.queue.sync {}

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 7)
        #expect(stored.state == serverState)
        #expect(fixture.host.revisions.isEmpty)
    }

    @Test("a snapshot claiming an unfetched future revision is discarded")
    func futureRevisionCaptureIsDiscarded() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        let serverState = Data(#"{"title":"server"}"#.utf8)
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: serverState,
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"future capture"}"#.utf8),
            baseRevision: 9
        )
        fixture.coordinator.queue.sync {}

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 7)
        #expect(stored.state == serverState)
        #expect(fixture.host.revisions.isEmpty)
    }

    @Test("a reconnect accepts newer server state instead of overwriting it")
    func reconnectAcceptsAdvancedServerRevision() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"initial"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        fixture.coordinator.queue.sync {
            fixture.coordinator.proxyLease = nil
            fixture.coordinator.runtimeStateSynchronized = false
        }
        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"offline edit"}"#.utf8),
            baseRevision: 7
        )
        fixture.coordinator.queue.sync {}
        let advancedState = Data(#"{"title":"other client"}"#.utf8)
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 8,
            updatedAtUnixMilliseconds: 2,
            state: advancedState,
            ptySessions: Data("[]".utf8)
        ))

        await Self.synchronize(fixture)

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 8)
        #expect(stored.state == advancedState)
        #expect(fixture.host.documents.map(\.revision) == [7, 8])
        #expect(fixture.host.revisions.isEmpty)
    }

    @Test("an empty same-slot reset rebases the workspace before the next upload")
    func emptySameSlotResetRebasesNextUpload() async throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"before-reset"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        await Self.synchronize(fixture)

        fixture.coordinator.queue.sync {
            fixture.coordinator.proxyLease = nil
            fixture.coordinator.runtimeStateSynchronized = false
        }
        fixture.provider.tunnel.seedRuntimeState(nil)
        await Self.synchronize(fixture)

        fixture.coordinator.enqueueRuntimeState(
            schemaVersion: 1,
            state: Data(#"{"title":"after-reset"}"#.utf8),
            baseRevision: 0
        )
        await Self.drainRuntimeStatePublication(fixture)

        #expect(fixture.host.revisions == [0, 1])
        #expect(try fixture.provider.tunnel.getRuntimeState()?.revision == 1)
    }

    private static func synchronize(_ fixture: RemoteRuntimeStateCoordinatorFixture) async {
        beginSynchronization(fixture)
        await drainRuntimeStatePublication(fixture)
    }

    private static func beginSynchronization(_ fixture: RemoteRuntimeStateCoordinatorFixture) {
        fixture.coordinator.queue.sync {
            fixture.coordinator.proxyLease = fixture.lease
            fixture.coordinator.daemonReady = true
            fixture.coordinator.runtimeStateCapabilityAvailable = true
            fixture.coordinator.runtimeStateSynchronized = false
            fixture.coordinator.synchronizeRuntimeStateLocked()
        }
    }

    private static func beginSynchronizationAsynchronously(
        _ fixture: RemoteRuntimeStateCoordinatorFixture
    ) {
        let coordinator = fixture.coordinator
        coordinator.queue.sync {
            coordinator.proxyLease = fixture.lease
            coordinator.daemonReady = true
            coordinator.runtimeStateCapabilityAvailable = true
            coordinator.runtimeStateSynchronized = false
        }
        coordinator.queue.async {
            coordinator.synchronizeRuntimeStateLocked()
        }
    }

    private static func connectThroughProductionProxy(_ fixture: RemoteRuntimeStateCoordinatorFixture) {
        fixture.lease.release()
        fixture.coordinator.queue.sync {
            fixture.coordinator.daemonReady = true
            fixture.coordinator.daemonRemotePath = "/remote/cmuxd"
            fixture.coordinator.runtimeStateCapabilityAvailable = true
            fixture.coordinator.remotePortScanningEnabled = false
            fixture.coordinator.startProxyLocked()
        }
        fixture.coordinator.queue.sync {}
    }

    private static func drainRuntimeStatePublication(_ fixture: RemoteRuntimeStateCoordinatorFixture) async {
        while true {
            let tasks = fixture.coordinator.queue.sync {
                (
                    rpc: fixture.coordinator.runtimeStateRPCTask,
                    publication: fixture.coordinator.runtimeStatePublicationTask
                )
            }
            if let task = tasks.rpc {
                await task.value
                fixture.coordinator.queue.sync {}
                continue
            }
            if let task = tasks.publication {
                await task.value
                fixture.coordinator.queue.sync {}
                continue
            }
            fixture.coordinator.queue.sync {}
            return
        }
    }

    private static func fixture(
        host: RuntimeStateRecordingHost = RuntimeStateRecordingHost(),
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()
    ) -> RemoteRuntimeStateCoordinatorFixture {
        RemoteRuntimeStateCoordinatorFixture(host: host, clock: clock)
    }

    private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
            }
        }
    }
}

private final class RuntimeStateRetryClock: RemoteProxyRetryClock, @unchecked Sendable {
    let sleepScheduled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func sleep(forMilliseconds _: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
            sleepScheduled.signal()
        }
    }

    func advance() {
        let continuation = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }
}
