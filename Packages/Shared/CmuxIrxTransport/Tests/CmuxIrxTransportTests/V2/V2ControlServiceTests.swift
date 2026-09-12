import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1))) struct V2ControlServiceTests {
    private let now = 1_789_000_000

    private func device() -> V2DeviceDescriptor {
        V2DeviceDescriptor(
            endpointID: String(repeating: "a", count: 64),
            identity: V2Identity(appNamespace: "com.cmux.test", buildTag: "test", deviceID: "device", environment: "test", projectID: "project", teamID: "team", userID: "user"),
            identityGeneration: 0,
            metadata: V2DeviceMetadata(appVersion: "2.0", capabilities: ["terminal"], displayName: "Test phone", pairingEnabled: true, platform: .ios, relayURLs: ["https://relay.example.com/"])
        )
    }

    private func service(backend: V2TestBackend, store: V2TestStateStore = V2TestStateStore()) throws -> V2ControlService {
        let fixedNow = now
        return V2ControlService(
            configuration: try V2ControlConfiguration(baseURL: URL(string: "https://control.example.com")!, device: device()),
            dependencies: V2ControlDependencies(connect: { try await backend.connect($0) }, http: { try await backend.http($0) }, stackAccessToken: { _ in "existing-stack-session" }, sign: { _ in Data(repeating: 1, count: 64) }, now: { Date(timeIntervalSince1970: Double(fixedNow)) }, jitter: { 0.5 }),
            store: store
        )
    }

    private func ready(_ service: V2ControlService) async throws -> V2ControlSnapshot {
        let events = await service.events()
        for await snapshot in events {
            if snapshot.status == .ready { return snapshot }
            if snapshot.status == .stopped, let failure = snapshot.failure { throw failure }
        }
        throw V2ControlFailure.stopped
    }

    @Test func enrollmentThenResumeUsesOneRegistrationAndSignedTicket() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        let first = await backend.currentSocket()
        #expect(await first.sentSchemas.filter { $0 == "device.register.v1" }.count == 1)
        await backend.markEnrolled()
        await service.stop()
        await service.start()
        _ = try await ready(service)
        let resumed = await backend.currentSocket()
        #expect(await resumed.sentSchemas.contains("device.register.v1") == false)
        let setups = await backend.handshakes
        let auth = await backend.authorizations
        #expect(setups.count == 2)
        #expect(setups[0].proof != nil)
        #expect(setups[1].proof != nil)
        #expect(setups[0].proof?.nonce != setups[1].proof?.nonce)
        #expect(setups.allSatisfy { $0.proof?.nonce.count == 22 })
        #expect(auth[0] == "Bearer existing-stack-session")
        #expect(auth[1] == "IrohTicket initial-ticket")
        await service.stop()
    }

    @Test func renewalsAndForegroundKeepTheSameSocket() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        let socket = await backend.currentSocket()
        let ticket = try await service.refreshAPITicket()
        let relay = try await service.refreshRelayCredentials()
        _ = try await service.refreshRelayCredentials()
        await service.foreground()
        #expect(ticket.token == "replacement-ticket")
        #expect(!relay.isEmpty)
        #expect(await backend.sockets.count == 1)
        #expect(await socket.closeCount == 0)
        #expect(await socket.pingCount == 1)
        #expect(await socket.sentSchemas.contains("ping") == false)
        #expect(await socket.sentSchemas.filter { $0 == "device.register.v1" }.count == 1)
        await service.stop()
    }

    @Test func workspaceSnapshotsUseTheExistingControlSocket() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        let snapshot = V2WorkspaceSnapshotRequestSnapshot(
            terminals: [PurpleTerminal(agent: "codex", cwd: "/work", id: "term", title: "Shell", workspaceID: "ws")],
            workspaces: [PurpleWorkspace(focused: true, id: "ws", index: 0, name: "Workspace")]
        )
        let response = try await service.publishWorkspaceSnapshot(snapshot, generation: "0", revision: 0)
        #expect(response.vmID == "device")
        #expect(response.snapshot.terminals.first?.title == "Shell")
        let fetched = try await service.refreshWorkspace(vmID: "device")
        #expect(fetched.schemaID == .workspaceSnapshotResultV1)
        #expect(await backend.sockets.count == 1)
        await service.stop()
    }

    @Test func rateLimitPreservesCredentialsAndOnlyBlocksItsOperation() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        let original = try await service.refreshRelayCredentials()
        let socket = await backend.currentSocket()
        await socket.rejectRelay(.rateLimited)
        do {
            _ = try await service.refreshRelayCredentials()
            Issue.record("Expected relay rate limit")
        } catch V2ControlFailure.server(let error) { #expect(error.code == .rateLimited) }
        do {
            _ = try await service.refreshRelayCredentials()
            Issue.record("Expected a local relay cooldown")
        } catch V2ControlFailure.cooldown(let schema, _) { #expect(schema == "relay.request.v1") }
        let directory = try await service.refreshDirectory()
        #expect(directory.devices.count == 1)
        #expect(await service.snapshot().cache.relayCredentials == original)
        #expect(await socket.closeCount == 0)
        await service.stop()
    }

    @Test func stopInvalidatesAnOutstandingReplyBeforeItCanChangeCache() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        _ = try await service.refreshRelayCredentials()
        let socket = await backend.currentSocket()
        await socket.holdRelayReplies()
        let pending = Task { try await service.refreshRelayCredentials() }
        await socket.waitForHeldRelay()
        await service.stop()
        let stopped = await service.snapshot()
        try await socket.releaseRelayReply()
        do { _ = try await pending.value; Issue.record("Stopped operation must fail") }
        catch V2ControlFailure.stopped {}
        #expect(await service.snapshot() == stopped)
        #expect(stopped.status == .stopped)
        #expect(await socket.closeCount == 1)
    }

    @Test func knownRevocationClearsAuthorityInTheCompleteSnapshot() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        _ = try await service.refreshRelayCredentials()
        _ = try await service.refreshDirectory()
        let socket = await backend.currentSocket()
        let events = await service.events()
        try await socket.push(V2RevokedResponse(deviceRecordID: "device-record", revision: 2, schemaID: .deviceRevokedV1, teamID: "team"))
        for await state in events where state.cache.authorityRevoked {
            #expect(state.cache.ticket == nil)
            #expect(state.cache.directory == nil)
            #expect(state.cache.relayCredentials.isEmpty)
            break
        }
        await service.stop()
    }

    @Test func unavailableSocketUsesOnlyTheVersionedHTTPRecoveryRoutes() async throws {
        let backend = V2TestBackend(now: now)
        await backend.disableSockets()
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        _ = try await service.refreshRelayCredentials()
        let directory = try await service.refreshDirectory()
        #expect(directory.devices.count == 1)
        #expect(await backend.sockets.isEmpty)
        let requests = await backend.httpRequests
        #expect(requests.first?.url?.path == "/v2/control/session")
        #expect(requests.dropFirst().allSatisfy { $0.url?.path == "/v2/requests" })
        #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "x-cmux-v2-setup") != nil })
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        await service.stop()
    }

    @Test func deliveryCheckpointIsEchoedWithoutWaitingForAnApplicationObserverOrReply() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        let socket = await backend.currentSocket()
        // No observer consumes the change. The transport still releases the batch.
        try await socket.push(V2ChangedResponse(deliveryReceipt: V2DeliveryReceipt(sequence: 16, token: "receipt-token"), revision: 1, schemaID: .directoryChangedV1, teamID: "team"))
        await socket.waitForAcknowledgement()
        let acknowledgements = await socket.acknowledgements
        #expect(acknowledgements.count == 1)
        #expect(acknowledgements[0].sequence == 16)
        #expect(acknowledgements[0].token == "receipt-token")
        _ = try await service.refreshRelayCredentials()
        #expect(await backend.sockets.count == 1)
        #expect(await socket.closeCount == 0)
        await service.stop()
    }

    @Test func uncertainSocketMutationKeepsItsRequestIDWhenRecoveringThroughHTTP() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        let socket = await backend.currentSocket()
        await socket.dropNextMetadataReply()
        let metadata = V2DeviceMetadata(appVersion: "2.0", capabilities: ["terminal"], displayName: "Updated phone", pairingEnabled: true, platform: .ios, relayURLs: ["https://relay.example.com/"])
        try await service.updateMetadata(metadata)
        let originalID = await socket.lastMetadataRequestID
        let requests = await backend.httpRequests
        let recovered = try JSONDecoder().decode(V2MetadataRequest.self, from: #require(requests.last?.httpBody))
        #expect(recovered.requestID == originalID)
        #expect(recovered.metadata == metadata)
        #expect(await backend.sockets.count == 1)
        await service.stop()
    }

    @Test func protocolCloseCodesPreserveBoundedRetryPolicy() throws {
        let service = try service(backend: V2TestBackend(now: now))
        #expect(V2URLSessionSocket.closeFailure(code: 1008, reason: Data("device_revoked".utf8)) == .socketClosed(code: 1008, reason: "device_revoked"))
        #expect(V2URLSessionSocket.closeFailure(code: 1009, reason: Data("untrusted free text".utf8)) == .socketClosed(code: 1009, reason: nil))
        _ = service
    }

    @Test func permanentClosesStopWhileCapacityClosesBackOff() async throws {
        let service = try service(backend: V2TestBackend(now: now))
        #expect(await service.terminal(.socketClosed(code: 1008, reason: "device_revoked")))
        #expect(await service.terminal(.socketClosed(code: 1009, reason: "payload_too_large")))
        #expect(await service.retryDelay(.socketClosed(code: 1013, reason: "slow_consumer"), attempt: 0) >= 60)
        #expect(await service.terminal(.socketClosed(code: 1011, reason: "transport_error")) == false)
    }

    @Test func paginationPinsRevisionAndRestartsAfterConcurrentChange() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        _ = try await service.refreshDirectory()
        let socket = await backend.currentSocket()
        await socket.changeDirectoryDuringPagination()
        let directory = try await service.refreshDirectory()
        #expect(directory.revision == 3)
        #expect(directory.devices.count == 2)
        #expect(directory.inboundPeers?.map(\.device.deviceRecordID) == ["inbound-2", "inbound-3"])
        #expect(directory.inboundPeers?.map(\.permissionExpiresAt) == [now + 3602, now + 3603])
        #expect(await socket.directoryRevisions == [nil, 2, nil, 3])
        #expect(await service.snapshot().cache.directory?.revision == 3)
        await service.stop()
    }

    @Test func retiredSchemaWaitsAnHourButAllowsAnExplicitRetry() async throws {
        let backend = V2TestBackend(now: now)
        let service = try service(backend: backend)
        await service.start()
        _ = try await ready(service)
        _ = try await service.refreshRelayCredentials()
        let socket = await backend.currentSocket()
        await socket.rejectRelay(.clientUpgradeRequired)
        do { _ = try await service.refreshRelayCredentials(); Issue.record("Expected retired schema") }
        catch V2ControlFailure.server(let error) { #expect(error.code == .clientUpgradeRequired) }
        do { _ = try await service.refreshRelayCredentials(); Issue.record("Expected long cooldown") }
        catch V2ControlFailure.cooldown(_, let until) {
            #expect(until.timeIntervalSince1970 - Double(now) >= 3600)
            #expect(until.timeIntervalSince1970 - Double(now) <= 3960)
        }
        await socket.rejectRelay(nil)
        await service.explicitRetry(schemaID: "relay.request.v1")
        _ = try await service.refreshRelayCredentials()
        #expect(await backend.sockets.count == 1)
        await service.stop()
    }
}
