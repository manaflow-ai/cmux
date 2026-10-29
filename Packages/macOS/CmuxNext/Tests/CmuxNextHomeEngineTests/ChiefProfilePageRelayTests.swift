import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import CmuxNextIPC
import CmuxNextWakeups
import Foundation
import Testing

/// The Chief editor's calls go on one `home-channels` page stream of the owner's page-relay
/// connection: no connection of the relay's own, the stream's epoch is the owner
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
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: ManualIdleDeadline())
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
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: ManualIdleDeadline())
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
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: ManualIdleDeadline())
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
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: ManualIdleDeadline())
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
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: ManualIdleDeadline())
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
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: ManualIdleDeadline())
        let params: [String: JSONValue] = ["display_name": .string("Ship")]
        _ = try await pageRelay.send(operation: "chief.profile.create", params: params, idempotencyKey: "k1", gestureEvent: 5)
        // The same event backs no second call: that one goes as the page.
        _ = try await pageRelay.send(operation: "chief.profile.create", params: params, idempotencyKey: "k2", gestureEvent: 5)
        #expect(owner.confirmations.count == 1)
        let issued = try #require(owner.confirmations.first)
        #expect(issued.operation == "chief.profile.create")
        #expect(issued.paramsSha256 == (try ResourceRelayClient.paramsDigest(params, operation: "chief.profile.create")))
        #expect(issued.relayConnectionID == "c1")
        let origins = await relay.opened[0].sent.map(\.origin)
        #expect(origins == [.object(["claim": .string("user"), "confirmation": .string("token-1")]),
                            .object(["claim": .string("page")])])
    }

    /// Settings > Agents > Chiefs and Home: 30 s after the editor's last call the
    /// owner has no page-relay client of this relay; a call in between keeps it, and the next call
    /// opens a new stream.
    @Test func theStreamClosesThirtySecondsAfterTheLastCall() async throws {
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerA, "c1"), Self.epoch(Self.ownerA, "c2")])
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let deadline = ManualIdleDeadline()
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: deadline)
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        #expect(deadline.armed?.delay == PageRelayIdleClose.delay)
        #expect(PageRelayIdleClose.delay == .seconds(30))
        let first = try #require(await relay.opened.first)
        #expect(await first.isOpen, "the close waits out the idle delay")

        // A second call before the deadline keeps the stream and arms the close again.
        _ = try await pageRelay.send(operation: "chief.profile.get", params: ["chief": .string("c")], idempotencyKey: nil, gestureEvent: nil)
        #expect(await relay.opened.count == 1)
        deadline.fire()
        await pageRelay.closing?.value
        #expect(!(await first.isOpen), "0 page-relay clients 30 s after the last call")
        #expect(deadline.armed == nil)

        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        let streams = await relay.opened
        #expect(streams.count == 2, "the next call opens a new stream")
        #expect(await streams[1].isOpen)
        #expect(await streams[1].sent.map(\.operation) == ["chief.profile.list"])
    }

    /// A deadline that fires while a call runs does nothing: the stream closes only once idle.
    @Test func aCallInFlightKeepsTheStream() async throws {
        let relay = FakePageRelay(epochs: [Self.epoch(Self.ownerA, "c1")])
        let owner = FakeChiefOwner(attached: Self.ownerA, relay: relay)
        let deadline = ManualIdleDeadline()
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: deadline)
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        let stale = try #require(deadline.armed?.action)
        owner.onAttachedOwner = { stale() }
        _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        #expect(pageRelay.closing == nil, "the stale wake found the stream in use")
        let streams = await relay.opened
        #expect(streams.count == 1)
        #expect(await streams[0].isOpen)
        #expect(await streams[0].sent.count == 2)
    }

    @Test func noCallWithoutAnAttachedOwner() async throws {
        let relay = FakePageRelay(epochs: [])
        let owner = FakeChiefOwner(attached: nil, relay: relay)
        let pageRelay = ChiefProfilePageRelay(owner: owner, idle: ManualIdleDeadline())
        await #expect(throws: DaemonError.notConnected) {
            _ = try await pageRelay.send(operation: "chief.profile.list", params: [:], idempotencyKey: nil, gestureEvent: nil)
        }
        #expect(await relay.pages.isEmpty)
        #expect(owner.sockets.isEmpty)
    }
}

/// The idle close's deadline, fired by the test.
@MainActor
final class ManualIdleDeadline: PageRelayIdleDeadline {
    private(set) var armed: (delay: Duration, action: @MainActor () -> Void)?

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) { armed = (delay, action) }
    func cancel() { armed = nil }

    func fire() {
        let action = armed?.action
        armed = nil
        action?()
    }
}

/// The owner's attached process, its confirmations and its page relay.
@MainActor
private final class FakeChiefOwner: ChiefProfileRelayOwner {
    var attached: ChiefProfilePageRelay.OwnerKey?
    let relay: FakePageRelay
    private(set) var sockets: [String] = []
    private(set) var confirmations: [V2OriginConfirmationIssueRequest] = []

    init(attached: ChiefProfilePageRelay.OwnerKey?, relay: FakePageRelay) {
        self.attached = attached
        self.relay = relay
    }

    /// Runs inside the next call, before it opens or uses a stream.
    var onAttachedOwner: (@MainActor () -> Void)?

    func attachedOwner() async -> ChiefProfilePageRelay.OwnerKey? {
        let hook = onAttachedOwner
        onAttachedOwner = nil
        hook?()
        return attached
    }

    func issueConfirmation(_ request: V2OriginConfirmationIssueRequest) async throws -> V2OriginConfirmation {
        confirmations.append(request)
        return V2OriginConfirmation(expiresAt: "1700000060000", token: "token-\(confirmations.count)")
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
        let stream = FakePageStream(page: page, epoch: epochs.removeFirst(), failsFirstSend: firstSendFails)
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
    private var failsFirstSend: DaemonError?
    private var open = true
    private(set) var sent: [Sent] = []

    init(page: String, epoch: PageRelayEpoch, failsFirstSend: DaemonError?) {
        self.page = page
        self.epoch = epoch
        self.failsFirstSend = failsFirstSend
    }

    var isOpen: Bool { open }

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
