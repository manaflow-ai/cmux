import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CryptoKit
import Foundation
import Testing

@Suite("Session admission and channel rules")
struct SessionTests {
    @Test func helloWithAValidProofIsAdmitted() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (_, reply) = try await h.hello()
        #expect(reply["t"] == "hello.ok")
        #expect(reply["caps"] == .array(["device-proof", "read"]))
        #expect(await h.host.connectedInstalls() == [PhoneHarness.install])
    }

    @Test func helloWithoutProofIsRefusedAndTheSessionCloses() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (_, reply) = try await h.hello(try h.helloJSON(proof: nil))
        #expect(reply["t"] == "error")
        #expect(reply["code"] == "auth.unauthenticated")
        try await within {
            for await state in await h.phone.states() where state.isClosed || !state.isLive { return }
        }
    }

    @Test func unpairedDeviceIsForbidden() async throws {
        let h = try await PhoneHarness(devices: { _ in [] })
        defer { Task { await h.shutdown() } }
        let (_, reply) = try await h.hello()
        #expect(reply["code"] == "auth.forbidden")
    }

    @Test func channelsBeforeHelloAreRefused() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (_, reply) = try await h.open(.rpc, id: 1)
        #expect(reply["t"] == "channel.refused")
        #expect(reply["code"] == "auth.unauthenticated")
    }

    @Test func evenIdsAndUnknownKindsAreRefused() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (_, even) = try await h.open(.rpc, id: 2)
        #expect(even["t"] == "channel.refused")
        #expect(even["code"] == "validation.invalid")
        let (_, browser) = try await h.open(.browser, id: 3, params: ["tab": "tab_t1"])
        #expect(browser["code"] == "channel.unknown_kind")
    }

    @Test func registeredHandlersServeTheirKind() async throws {
        let handler = EchoHandler()
        let h = try await PhoneHarness(handlers: MobileChannelHandlers(channels: [.rd: handler]))
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (channel, opened) = try await h.open(.rd, id: 1, params: ["service": "desktop"])
        #expect(opened["t"] == "channel.opened")
        try await channel.send(binary: Data([1, 2, 3]))
        guard case .binary(let echo, _) = try await PhoneHarness.next(channel) else { Issue.record("no echo"); return }
        #expect(echo == Data([1, 2, 3]))
        #expect(await handler.principals == [PhoneHarness.install])
    }

    @Test func revocationClosesLiveChannels() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        await h.store.revoke(PhoneHarness.install)
        let closing = try await PhoneHarness.nextJSON(rpc)
        #expect(closing["t"] == "channel.closed")
        #expect(closing["code"] == "auth.revoked")
    }
}

/// A C3-style handler: accepts and echoes binary records.
actor EchoHandler: MobileChannelHandler {
    private(set) var principals: [String] = []

    func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
               gate: MobileSessionGate) async {
        principals.append(principal.install)
        try? await channel.send(frame: .channelOpened(ChannelOpenedFrame(channel: open.channel, window: 65536,
                                                                         params: ["media": "rd_datagrams"], resumed: false)))
        while case .binary(let data, _) = await channel.receive() {
            try? await channel.send(binary: data)
        }
    }
}
