import Foundation
import IrohLib
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct IrxDirectOnlyEndpointTests {
    private func supervisor() -> IrxEndpointSupervisor {
        IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
            identity: IrxIdentity(privateKeyData: IrxLiveTestSupport.identitySeed(),
                deviceID: "direct-test", appInstanceID: "direct-test"),
            pathMode: .directOnly, preferredBindAddress: "127.0.0.1:0",
            initialRemoteBiStreams: 0, initialRemoteUniStreams: 0),
            journal: IrxLiveTestSupport.journal())
    }

    @Test func directConnectionNeedsNoCredentialAndCannotAcquireARelay() async throws {
        let supervisor = supervisor()
        let endpoint = try await supervisor.readyEndpoint(credentials: [])
        #expect(await supervisor.isHealthy())
        #expect(endpoint.addr().relayUrl() == nil)

        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let accepting = Task {
            let incoming = try #require(await server.acceptNext())
            return try await incoming.accept().connect()
        }
        let address = EndpointAddr(id: server.id(), relayUrl: "https://must-not-contact.invalid/",
            addresses: IrxLiveTestSupport.loopbackAddr(of: server).directAddresses())
        let connection = try await supervisor.dial(address: address, credentials: [])
        let accepted = try await accepting.value
        #expect(connection.selectedPathDescription().hasPrefix("direct:"))

        await supervisor.rotateCredentials([IrxRelayCredential(
            relayURL: "https://must-not-contact.invalid/", token: "not-a-credential",
            expiresAt: Date().addingTimeInterval(1800), refreshAfter: Date().addingTimeInterval(1500))])
        #expect(endpoint.addr().relayUrl() == nil)
        #expect(await connection.isClosed == false)
        let sameEndpoint = try await supervisor.readyEndpoint(credentials: [])
        #expect(sameEndpoint === endpoint)

        await connection.close(code: .userRequested, origin: .local)
        try accepted.close(errorCode: 0, reason: Data())
        await supervisor.deactivate()
        try await server.close()
    }

    @Test func reusableCloseRebindsButDeactivationNeverDoes() async throws {
        let supervisor = supervisor()
        let first = try await supervisor.readyEndpoint(credentials: [])
        await supervisor.close()
        #expect(first.isClosed())
        #expect(await supervisor.boundEndpoint() == nil)
        let second = try await supervisor.readyEndpoint(credentials: [])
        #expect(second !== first)
        #expect(second.id() == first.id())
        await supervisor.deactivate()
        do {
            _ = try await supervisor.readyEndpoint(credentials: [])
            Issue.record("A deactivated identity cannot open another socket")
        } catch IrxEndpointError.endpointClosed {}
        #expect(second.isClosed())
    }

    @Test func shutdownDuringRelayReadinessCannotPublishTheOldEndpoint() async throws {
        let supervisor = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
            identity: IrxIdentity(privateKeyData: IrxLiveTestSupport.identitySeed(),
                deviceID: "cancel-bind", appInstanceID: "cancel-bind"),
            pathMode: .relayOnly, preferredBindAddress: "127.0.0.1:0",
            initialRemoteBiStreams: 0, initialRemoteUniStreams: 0),
            journal: IrxLiveTestSupport.journal())
        let binding = Task {
            try await supervisor.readyEndpoint(credentials: [IrxRelayCredential(
                relayURL: "https://127.0.0.1:9", token: "unavailable-local-test-relay",
                expiresAt: Date().addingTimeInterval(1800), refreshAfter: Date().addingTimeInterval(1500))])
        }
        let bound = try await withIrxDeadline(.seconds(3), onTimeout: {}) {
            while !Task.isCancelled {
                if await supervisor.boundEndpoint() != nil { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        guard bound == true else {
            await supervisor.deactivate()
            binding.cancel()
            Issue.record("Expected UDP binding before relay readiness")
            return
        }
        await supervisor.deactivate()
        do {
            _ = try await binding.value
            Issue.record("An in-flight bind must fail after deactivation")
        } catch { /* Cancellation and native closure both invalidate the bind. */ }
        #expect(await supervisor.boundEndpoint() == nil)
        #expect(await supervisor.isHealthy() == false)
    }

    @Test func relayOnlyTargetIsRejectedBeforeAnyEndpointOpens() async throws {
        let supervisor = supervisor()
        let target = EndpointAddr(id: try EndpointId.fromString(s: String(repeating: "a", count: 64)),
            relayUrl: "https://must-not-contact.invalid/", addresses: [])
        do {
            _ = try await supervisor.dial(address: target, credentials: [])
            Issue.record("A direct-only endpoint must reject a target without a local address")
        } catch IrxEndpointError.noDirectAddress {}
        #expect(await supervisor.boundEndpoint() == nil)
        await supervisor.deactivate()
    }
}
