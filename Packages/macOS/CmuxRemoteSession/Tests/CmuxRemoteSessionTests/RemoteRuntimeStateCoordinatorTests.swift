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

    private static func drainRuntimeStatePublication(_ fixture: RemoteRuntimeStateCoordinatorFixture) async {
        while let task = fixture.coordinator.queue.sync(
            execute: { fixture.coordinator.runtimeStatePublicationTask }
        ) {
            await task.value
            fixture.coordinator.queue.sync {}
        }
    }

    private static func fixture(
        host: RuntimeStateRecordingHost = RuntimeStateRecordingHost()
    ) -> RemoteRuntimeStateCoordinatorFixture {
        RemoteRuntimeStateCoordinatorFixture(host: host)
    }
}
