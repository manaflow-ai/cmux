import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CmuxTerminalLink
import CmuxTerminalRenderCore
import CryptoKit
import Foundation
import Testing

@Suite("mobile link client")
struct MobileLinkClientTests {
    @Test func anUnpairedDeviceIsRefusedAtHelloAndTheTerminalSaysSo() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let stranger = MobileLinkClient(
            hostID: TerminalHarness.hostID,
            signer: SoftwareSigner(install: "in_stranger", keyID: "k9", key: P256.Signing.PrivateKey()),
            client: HelloClient(install: "in_stranger", platform: "ios", appVersion: "1.0"),
            makeSession: { [network = h.network] in
                LinkSession(peer: LinkPeer(hostID: TerminalHarness.hostID),
                            selector: PathSelector(carriers: [network.carrier(kind: .direct, path: .direct)],
                                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                            configuration: TerminalHarness.fast)
            })
        let source = LinkTerminalByteSource(terminal: "term_x1", client: stranger)
        let log = EventLog(try await source.open(TerminalViewport(cols: 40, rows: 20, visible: true)))
        #expect(try await log.closed() == TerminalLinkFailure.unauthorized(code: "auth.forbidden").defaultText)
        guard case .unauthorized? = await source.lastFailure() else {
            Issue.record("expected an unauthorized failure")
            return
        }
        await source.close()
        await stranger.close()
    }

    @Test func channelsOfOneSessionShareOneHelloAndUseOddIDs() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let request = MobileChannelRequest(kind: .rpc, channelClass: .interactive, window: 65_536, params: [:],
                                           stream: "rpc", priority: .control)
        let first = try await h.client.open(request)
        let second = try await h.client.open(request)
        #expect(first.channel.id == 1)
        #expect(second.channel.id == 3)
        #expect(first.generation == second.generation)
        #expect(await h.client.currentGeneration == 1)
    }
}
