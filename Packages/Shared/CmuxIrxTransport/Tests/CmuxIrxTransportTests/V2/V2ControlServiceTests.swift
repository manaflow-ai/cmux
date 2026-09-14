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
            dependencies: V2ControlDependencies(connect: { try await backend.connect($0) }, stackAccessToken: { _ in "existing-stack-session" }, sign: { _ in Data(repeating: 1, count: 64) }, now: { Date(timeIntervalSince1970: Double(fixedNow)) }, jitter: { 0.5 }),
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
        #expect(setups[0].proof == nil)
        #expect(setups[1].proof != nil)
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
}
