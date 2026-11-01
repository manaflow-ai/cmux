import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextDaemonService

@Suite struct CloudTurnAttachmentTests {
    private actor Link {
        var ticket: Int? = 1
        var stateCalls = 0
        var captures = 0
        func replace() { ticket = 2 }
        func state() -> Data { stateCalls += 1; return Data() }
        func capture() -> Data { captures += 1; return Data() }
    }

    @Test func staleAttachmentCannotBorrowAReplacementOwnerProof() async throws {
        let link = Link()
        let turn = RemoteAcpmuxWire.CloudTurn(state: { _, _ in await link.state() }, capture: { _, _, _, _ in await link.capture() })
        let attachment = CloudTurnAttachment(endpoint: { .init(socketPath: "/fixture/cloud.sock") }, ownerLink: { await link.ticket }, turn: turn)
        let bound = try #require(attachment.turn)
        await #expect(throws: AgentSessionRemoteError.self) { try await bound.state("session", "turn") }
        _ = try await attachment.endpoint()
        _ = try await bound.state("session", "turn")
        await link.replace()
        await #expect(throws: AgentSessionRemoteError.self) { try await bound.state("session", "turn") }
        await #expect(throws: AgentSessionRemoteError.self) { try await bound.capture("session", "turn", Data(), Data()) }
        await #expect(throws: AgentSessionRemoteError.self) { try await attachment.endpoint() }
        #expect(await link.stateCalls == 1)
        #expect(await link.captures == 0)
        let fresh = CloudTurnAttachment(endpoint: { .init(socketPath: "/fixture/replacement.sock") }, ownerLink: { await link.ticket }, turn: turn)
        _ = try await fresh.endpoint()
        _ = try await #require(fresh.turn).state("session", "turn")
        #expect(await link.stateCalls == 2)
    }

    @Test func linkChangingDuringEndpointResolutionCannotBind() async throws {
        let link = Link()
        let attachment = CloudTurnAttachment(endpoint: {
            await link.replace()
            return .init(socketPath: "/fixture/stale.sock")
        }, ownerLink: { await link.ticket }, turn: .init(state: { _, _ in await link.state() }, capture: { _, _, _, _ in await link.capture() }))
        await #expect(throws: AgentSessionRemoteError.self) { try await attachment.endpoint() }
        let bound = try #require(attachment.turn)
        await #expect(throws: AgentSessionRemoteError.self) { try await bound.state("session", "turn") }
        #expect(await link.stateCalls == 0)
    }

    @Test func linkChangingWhileOwnerAuthorizesCannotReleaseCapability() async throws {
        let link = Link()
        let attachment = CloudTurnAttachment(endpoint: { .init(socketPath: "/fixture/cloud.sock") }, ownerLink: { await link.ticket }, turn: .init(state: { _, _ in
            await link.replace()
            return await link.state()
        }, capture: { _, _, _, _ in await link.capture() }))
        _ = try await attachment.endpoint()
        let bound = try #require(attachment.turn)
        await #expect(throws: AgentSessionRemoteError.self) { try await bound.state("session", "turn") }
        #expect(await link.stateCalls == 1)
        #expect(await link.captures == 0)
    }
}
