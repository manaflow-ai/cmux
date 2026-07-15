import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote runtime state coordinator", .serialized)
struct RemoteRuntimeStateCoordinatorTests {
    @Test("server state wins over a snapshot queued before the initial fetch")
    func serverWinsInitialSynchronization() throws {
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

        Self.synchronize(fixture)

        #expect(fixture.host.documents.map(\.revision) == [7])
        #expect(fixture.host.revisions.isEmpty)
        let storedState = try fixture.provider.tunnel.getRuntimeState()?.state
        #expect(storedState == serverState)
    }

    @Test("an empty server is seeded from the queued workspace snapshot")
    func emptyServerIsSeeded() throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        let localState = Data(#"{"title":"local-seed"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(schemaVersion: 1, state: localState)
        fixture.coordinator.queue.sync {}

        Self.synchronize(fixture)

        #expect(fixture.host.documents.isEmpty)
        #expect(fixture.host.revisions == [1])
        let storedState = try fixture.provider.tunnel.getRuntimeState()?.state
        #expect(storedState == localState)
    }

    @Test("a later snapshot retries a transient initial fetch failure before uploading")
    func autosaveRetriesInitialFetchFailure() throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.failNextRuntimeStateGet()

        Self.synchronize(fixture)
        #expect(!fixture.coordinator.runtimeStateSynchronized)

        let localState = Data(#"{"title":"retry-seed"}"#.utf8)
        fixture.coordinator.enqueueRuntimeState(schemaVersion: 1, state: localState)
        fixture.coordinator.queue.sync {}

        #expect(fixture.coordinator.runtimeStateSynchronized)
        #expect(fixture.host.documents.isEmpty)
        #expect(fixture.host.revisions == [1])
        let storedState = try fixture.provider.tunnel.getRuntimeState()?.state
        #expect(storedState == localState)
    }

    @Test("a reconnect uploads local edits when the server revision has not advanced")
    func reconnectPreservesPendingLocalEdit() throws {
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
        Self.synchronize(fixture)

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

        Self.synchronize(fixture)

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 8)
        #expect(stored.state == offlineEdit)
        #expect(fixture.host.documents.map(\.revision) == [7])
        #expect(fixture.host.revisions == [8])
    }

    @Test("a snapshot captured before initial restore cannot overwrite fetched state")
    func staleInitialCaptureIsDiscarded() throws {
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
        Self.synchronize(fixture)

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

    @Test("a reconnect accepts newer server state instead of overwriting it")
    func reconnectAcceptsAdvancedServerRevision() throws {
        let fixture = Self.fixture()
        defer { fixture.stop() }
        fixture.provider.tunnel.seedRuntimeState(RemoteRuntimeStateDocument(
            schemaVersion: 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1,
            state: Data(#"{"title":"initial"}"#.utf8),
            ptySessions: Data("[]".utf8)
        ))
        Self.synchronize(fixture)

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

        Self.synchronize(fixture)

        let storedDocument = try fixture.provider.tunnel.getRuntimeState()
        let stored = try #require(storedDocument)
        #expect(stored.revision == 8)
        #expect(stored.state == advancedState)
        #expect(fixture.host.documents.map(\.revision) == [7, 8])
        #expect(fixture.host.revisions.isEmpty)
    }

    private static func synchronize(_ fixture: RemoteRuntimeStateCoordinatorFixture) {
        fixture.coordinator.queue.sync {
            fixture.coordinator.proxyLease = fixture.lease
            fixture.coordinator.daemonReady = true
            fixture.coordinator.runtimeStateCapabilityAvailable = true
            fixture.coordinator.runtimeStateSynchronized = false
            fixture.coordinator.synchronizeRuntimeStateLocked()
        }
    }

    private static func fixture() -> RemoteRuntimeStateCoordinatorFixture {
        RemoteRuntimeStateCoordinatorFixture()
    }
}
