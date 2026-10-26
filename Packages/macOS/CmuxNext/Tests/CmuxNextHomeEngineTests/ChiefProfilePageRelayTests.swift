import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief editor's calls go on one `home-channels` page stream of the owner's page-relay
/// connection (p05-ipc-108): no connection of the relay's own, the stream's epoch is the owner
/// pid/generation check, and a gesture's token is bound to the stream.
@MainActor
@Suite struct ChiefProfilePageRelayTests {
    static let socket = "/tmp/chief-owner.sock"
    static let ownerA = ChiefProfilePageRelay.OwnerKey(socket: socket, pid: 41, generation: "gen-a")
    static let ownerB = ChiefProfilePageRelay.OwnerKey(socket: socket, pid: 42, generation: "gen-b")

    static func epoch(_ owner: ChiefProfilePageRelay.OwnerKey, _ connection: String) -> PageRelayEpoch {
        PageRelayEpoch(pid: owner.pid, generation: owner.generation, connectionID: connection)
    }

    @Test func callsShareOneHomeChannelsStream() async throws {
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerA, "c1")])
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner)
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        _ = try await pageRelay.send(operation: "chief.profile.get", params: ["chief": .string("c")], idempotencyKey: nil, gestureEvent: nil)
        #expect(await relay.pages == ["home-channels"])
        let streams = await relay.opened
        #expect(streams.count == 1)
        #expect(await streams[0].sent.map(\.operation) == ["chief.profile.list", "chief.profile.get"])
        #expect(await streams[0].sent.map(\.origin) == [.object(["claim": .string("page")]), .object(["claim": .string("page")])])
        #expect(owner.sockets == [Self.socket])
    }

    @Test func aStreamOfAnotherOwnerProcessTakesNoCall() async throws {
        // The socket already serves a restarted owner the main connection is not attached to.
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerB, "c1"), Self.epoch(Self.ownerB, "c2")])
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner)
        await #expect(throws: DaemonError.notConnected) {
            _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        }
        for stream in await relay.opened {
            #expect(await stream.sent.isEmpty)
            #expect(!(await stream.isOpen))
        }
        #expect(owner.confirmations.isEmpty)
    }

    @Test func aRestartedOwnerGetsANewStream() async throws {
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerA, "c1"), Self.epoch(Self.ownerB, "c2")])
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner)
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        owner.attached = Self.ownerB
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        let streams = await relay.opened
        #expect(streams.count == 2)
        #expect(!(await streams[0].isOpen))
        #expect(await streams[0].sent.count == 1)
        #expect(await streams[1].sent.count == 1)
    }

    @Test func anEndedStreamIsReplaced() async throws {
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerA, "c1"), Self.epoch(Self.ownerA, "c2")])
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner)
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        await relay.opened[0].close()
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        let streams = await relay.opened
        #expect(streams.count == 2)
        #expect(await streams[1].sent.count == 1)
    }

    @Test func aStreamLostUnderACallGoesOnceMoreOnANewOne() async throws {
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerA, "c1"), Self.epoch(Self.ownerA, "c2")],
                                  firstSendFails: .connectionClosed(reason: "owner restarted"))
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner)
        let result = try await pageRelay.send(operation: "chief.profile.update", params: ["chief": .string("c"), "display_name": .string("Ship")],
                                              idempotencyKey: "k1", gestureEvent: nil)
        #expect(result == .object(["ok": .bool(true)]))
        let streams = await relay.opened
        #expect(streams.count == 2)
        #expect(await streams[0].sent.isEmpty)
        #expect(await streams[1].sent.map(\.idempotencyKey) == ["k1"])
    }

    @Test func aGestureCallIsTheUsersOnceWithATokenBoundToItsStream() async throws {
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerA, "c1")])
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner)
        let params: [String: JSONValue] = ["display_name": .string("Ship")]
        _ = try await pageRelay.send(operation: "chief.profile.create", params: params, idempotencyKey: "k1", gestureEvent: 5)
        // The same event backs no second call: that one goes as the page.
        _ = try await pageRelay.send(operation: "chief.profile.create", params: params, idempotencyKey: "k2", gestureEvent: 5)
        #expect(owner.confirmations.count == 1)
        let issued = try #require(owner.confirmations.first)
        #expect(issued["operation"] == .string("chief.profile.create"))
        #expect(issued["params_sha256"] == .string(try ResourceRelayClient.paramsDigest(params, operation: "chief.profile.create")))
        #expect(issued["relay_connection_id"] == .string("c1"))
        #expect(issued["relay_stream"] == .number(1))
        let origins = await relay.opened[0].sent.map(\.origin)
        #expect(origins == [.object(["claim": .string("user"), "confirmation": .string("token-1")]),
                            .object(["claim": .string("page")])])
    }

    @Test func noCallWithoutAnAttachedOwner() async throws {
        let relay = FakePageRelay(epochs: [])
        let owner = FakeChiefOwner(attached: nil, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner)
        await #expect(throws: DaemonError.notConnected) {
            _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        }
        #expect(await relay.pages.isEmpty)
        #expect(owner.sockets.isEmpty)
    }
}

/// The owner's attached process, its confirmations and its page relay.
@MainActor
private final class FakeChiefOwner: ChiefProfileRelayOwner {
    var attached: ChiefProfilePageRelay.OwnerKey?
    let relay: FakePageRelay
    private(set) var sockets: [String] = []
    private(set) var confirmations: [[String: JSONValue]] = []

    init(attached: ChiefProfilePageRelay.OwnerKey?, relay: FakePageRelay) {
        self.attached = attached
        self.relay = relay
    }

    func attachedOwner() async -> ChiefProfilePageRelay.OwnerKey? { attached }

    func issueConfirmation(_ params: [String: JSONValue]) async throws -> JSONValue {
        confirmations.append(params)
        return .object(["token": .string("token-\(confirmations.count)")])
    }

    func pageRelay(socket: String) -> any PageRelayStreamOpening {
        sockets.append(socket)
        return relay
    }
}

/// A page-relay connection that opens streams of the given epochs, in order.
private actor FakePageRelay: PageRelayStreamOpening {
    private var epochs: [PageRelayEpoch]
    private var firstSendFails: DaemonError?
    private(set) var pages: [String] = []
    private(set) var opened: [FakePageStream] = []

    init(epochs: [PageRelayEpoch], firstSendFails: DaemonError? = nil) {
        self.epochs = epochs
        self.firstSendFails = firstSendFails
    }

    func openStream(page: String) async throws -> any PageRelayStream {
        pages.append(page)
        guard !epochs.isEmpty else { throw DaemonError.notConnected }
        let stream = FakePageStream(page: page, epoch: epochs.removeFirst(), stream: 1, failsFirstSend: firstSendFails)
        firstSendFails = nil
        opened.append(stream)
        return stream
    }
}

private actor FakePageStream: PageRelayStream {
    struct Sent: Sendable {
        var operation: String
        var idempotencyKey: String?
        var origin: JSONValue
    }

    nonisolated let page: String
    nonisolated let epoch: PageRelayEpoch
    private nonisolated let stream: UInt16
    private var failsFirstSend: DaemonError?
    private var open = true
    private(set) var sent: [Sent] = []

    init(page: String, epoch: PageRelayEpoch, stream: UInt16, failsFirstSend: DaemonError?) {
        self.page = page
        self.epoch = epoch
        self.stream = stream
        self.failsFirstSend = failsFirstSend
    }

    var isOpen: Bool { open }

    nonisolated var confirmationBinding: [String: JSONValue] {
        ["relay_connection_id": .string(epoch.connectionID), "relay_stream": .number(Double(stream))]
    }

    func send(operation: String, params: [String: JSONValue], idempotencyKey: String?,
              origin: JSONValue) async throws -> JSONValue {
        guard open else { throw DaemonError.connectionClosed(reason: "stream ended") }
        if let failure = failsFirstSend {
            failsFirstSend = nil
            open = false
            throw failure
        }
        sent.append(Sent(operation: operation, idempotencyKey: idempotencyKey, origin: origin))
        return .object(["ok": .bool(true)])
    }

    func close() {
        open = false
    }
}
