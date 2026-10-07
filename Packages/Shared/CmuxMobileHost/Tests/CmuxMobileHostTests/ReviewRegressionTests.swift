import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CmuxTerminalStream
import CryptoKit
import Foundation
import Testing

@Suite("Review regressions")
struct ReviewRegressionTests {
    func flood(_ attachment: FakeAttachment, frames: Int = 40) {
        for index in 0..<frames {
            attachment.emit(.frame(TerminalFrame(kind: .bytes, generation: 7, offset: UInt64(index * 1000),
                                                 payload: Data(repeating: 0x61, count: 1000))))
        }
    }

    func waitFor(_ attachment: FakeAttachment, _ entry: String) async throws {
        try await within {
            while let next = await attachment.recorded.next() { if next == entry { return } }
            throw TimeoutError()
        }
    }

    @Test func revokingAPeerThatStoppedReadingStillClosesItsSession() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (_, opened) = try await h.open(.terminal, id: 3, params: PhoneHarness.terminalParams(), window: 4096, budget: 4096,
                                           priority: .render)
        #expect(opened["t"] == "channel.opened")
        let attachment = try await within { try #require(await h.daemon.attachments.next()) }
        flood(attachment)
        try await waitFor(attachment, "snapshot:gap")
        await h.store.revoke(PhoneHarness.install)
        // The phone never reads; the host still tears the session down after its grace.
        try await waitFor(attachment, "detach")
        #expect(await h.host.connectedInstalls().isEmpty)
    }

    @Test func aRevocationDuringAdmissionWins() async throws {
        let key = P256.Signing.PrivateKey()
        let store = StaticTrustStore(devices: [PairedDevice(install: PhoneHarness.install, userID: PhoneHarness.userID,
                                                            keyID: "k1", publicKey: key.publicKey.x963Representation)])
        let slow = SlowAuthorizer(inner: TrustStoreAuthorizer(hostID: PhoneHarness.hostID, accountUserID: PhoneHarness.userID,
                                                             store: store), store: store)
        let h = try await PhoneHarness(authorizer: slow, key: key)
        defer { Task { await h.shutdown() } }
        let hello = Task { try await h.hello() }
        try await within { await slow.entered.wait() }
        await store.revoke(PhoneHarness.install)
        try await within { await slow.revocationSeen.wait() }
        await slow.release.fire()
        let (_, reply) = try await hello.value
        #expect(reply["t"] == "error")
        #expect(reply["code"] == "auth.forbidden")
    }

    @Test func concurrentSendsKeepContiguousSeqsUnderCreditPressure() async throws {
        let h = try await PhoneHarness(handlers: MobileChannelHandlers(channels: [.rd: BurstHandler()]))
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (channel, opened) = try await h.open(.rd, id: 1, params: ["service": "desktop"], budget: 4096)
        #expect(opened["t"] == "channel.opened")
        var kinds: [String] = []
        for _ in 0..<3 {
            switch try await PhoneHarness.next(channel) {
            case .binary: kinds.append("binary")
            case .json: kinds.append("json")
            case .gap: kinds.append("gap")
            case .closed: kinds.append("closed")
            }
        }
        #expect(kinds.sorted() == ["binary", "binary", "json"])
    }

    @Test func channelCloseWhileBackpressuredEndsTheBridge() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (channel, _) = try await h.open(.terminal, id: 3, params: PhoneHarness.terminalParams(), window: 4096, budget: 4096,
                                            priority: .render)
        let attachment = try await within { try #require(await h.daemon.attachments.next()) }
        flood(attachment)
        try await waitFor(attachment, "snapshot:gap")
        try await channel.send(frame: .channelClose(ChannelCloseFrame(channel: 3)))
        try await waitFor(attachment, "detach")
    }

    @Test func aChangeDuringTheFirstLoadIsNotLost() async throws {
        let daemon = FakeDaemon()
        await daemon.setRaceFirstRead { $0.workspaces[0].name = "raced" }
        let h = try await PhoneHarness(daemon: daemon)
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .subscribe(SubscribeFrame(stream: "workspace:h_mac1")))
        let snapshot = try await PhoneHarness.nextJSON(rpc)
        #expect(snapshot["epoch"]?.stringValue?.hasPrefix("ep_") == true)
        if snapshot["state"]?["workspaces"] == .array([]) || snapshot["state"]?["workspaces"]?.firstName != "raced" {
            let event = try await PhoneHarness.nextJSON(rpc)
            #expect(event["op"] == "workspace.upsert")
            #expect(event["params"]?["workspace"]?["name"] == "raced")
            #expect(event["epoch"] == snapshot["epoch"])
        }
    }

    @Test func subscribeWithAnotherEpochGetsASnapshot() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        guard case .object(var subscribe) = try MobileFrame.subscribe(SubscribeFrame(stream: "workspace:h_mac1", afterSeq: 1000)).jsonValue
        else { return }
        subscribe["epoch"] = "ep_old"
        try await rpc.send(json: .object(subscribe))
        #expect(try await PhoneHarness.nextJSON(rpc)["t"] == "snapshot")
    }

    @Test func uplinkAnswersPendingKeySnapshotsOnlyToThatDeviceAndSettlesBadOps() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .op(OpFrame(op: "workspace.rename", params: .object(["workspace": "ws_a1", "name": "x"]),
                                              idempotencyKey: "key-pending-1")))
        _ = try await PhoneHarness.nextJSON(rpc)
        _ = try await PhoneHarness.nextJSON(rpc)
        let socket = FakeControlSocket()
        let run = Task { try await HostControlUplink(socket: socket, host: h.host, install: "in_mac1", appVersion: "1").run() }
        defer { run.cancel() }
        _ = try await socket.next()
        socket.deliver(try MobileFrame.helloOK(HelloOKFrame(version: 1, caps: [], serverTime: 0, maxFrame: 131_072)).jsonValue)
        _ = try await socket.next()
        _ = try await socket.next()
        socket.deliver(["t": "snapshot.request", "stream": "workspace:h_mac1", "to": "in_phone1", "pending": ["key-pending-1"]])
        let scoped = try await socket.next()
        #expect(scoped["t"] == "snapshot")
        #expect(scoped["to"] == "in_phone1")
        #expect(scoped["decided"] == [["idempotency_key": "key-pending-1", "ok": true, "sequence": .int(1001)]])
        socket.deliver(["t": "op", "op": 5, "idempotency_key": "key-bad-1", "from": "in_phone1"])
        let reject = try await socket.next()
        #expect(reject["t"] == "reject")
        #expect(reject["code"] == "validation.invalid")
        #expect(try await socket.next()["t"] == "request-settled")
    }
}

/// Sends a burst of concurrent records that exceed the link credit.
struct BurstHandler: MobileChannelHandler {
    func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
               gate: MobileSessionGate) async {
        try? await channel.send(frame: .channelOpened(ChannelOpenedFrame(channel: open.channel, window: 65536,
                                                                         params: [:], resumed: false)))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await channel.send(binary: Data(repeating: 1, count: 3500)) }
            group.addTask { try? await channel.send(binary: Data(repeating: 2, count: 3500)) }
            group.addTask { try? await channel.send(json: ["t": "rd.note"]) }
        }
        while case .binary = await channel.receive() {}
    }
}

/// Holds admission open until released, to race a revocation against it.
actor SlowAuthorizer: MobileDeviceAuthorizer {
    let inner: TrustStoreAuthorizer
    let store: StaticTrustStore
    let entered = OnceFlag()
    let release = OnceFlag()
    let revocationSeen = OnceFlag()

    init(inner: TrustStoreAuthorizer, store: StaticTrustStore) {
        self.inner = inner
        self.store = store
    }

    func authorize(_ request: DeviceAuthRequest) async -> Result<MobileDevicePrincipal, MobileAuthFailure> {
        // Check before the revocation lands, like a slow store lookup.
        let verdict = await inner.authorize(request)
        await entered.fire()
        await release.wait()
        return verdict
    }

    func authorizeForwarded(install: String, userID: String?) async -> Result<MobileDevicePrincipal, MobileAuthFailure> {
        await inner.authorizeForwarded(install: install, userID: userID)
    }

    func revocations() async -> AsyncStream<String> {
        let upstream = await store.revocations()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let seen = revocationSeen
        Task {
            for await install in upstream {
                continuation.yield(install)
                await seen.fire()
            }
            continuation.finish()
        }
        return stream
    }
}

actor OnceFlag {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

extension JSONValue {
    var firstName: String? {
        if case .array(let items) = self { return items.first?["name"]?.stringValue }
        return nil
    }
}
