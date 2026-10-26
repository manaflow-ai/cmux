@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Provider freeze hooks and the page relay channels (p13-webui-066): a frozen page's daemon relay
/// holds no live listen, its channel closes its daemon connection 30 s after the last listener and
/// call, and a thaw gives each stream one resync.
@MainActor
@Suite struct PageRelayChannelFreezeTests {
    /// A deadline the test fires by hand.
    @MainActor final class ManualDeadline: PageRelayIdleDeadline {
        private(set) var armed: (delay: Duration, action: @MainActor () -> Void)?
        func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) { armed = (delay, action) }
        func cancel() { armed = nil }

        func fire() {
            let action = armed?.action
            armed = nil
            action?()
        }
    }

    /// A relay channel over a fake daemon, with ``PageRelayChannel``'s listener rules: a connection
    /// opens on a use while none is open and closes on the idle close; a live listener and a running
    /// call keep it; a paused listener hears nothing and keeps nothing.
    @MainActor final class FakeRelayChannel: PageRelayListeners {
        let deadline = ManualDeadline()
        let idle: PageRelayIdleClose
        /// Daemon page-relay clients this channel has open now.
        private(set) var clients = 0
        private(set) var opened = 0
        private var listeners: [UInt64: (event: String, deliver: @MainActor (CmuxNextDaemon.JSONValue) -> Void, paused: Bool)] = [:]
        private var next: UInt64 = 0

        init() {
            idle = PageRelayIdleClose(deadline: deadline)
            idle.onIdle = { [unowned self] in self.clients = 0 }
        }

        func listen(event: String, onEvent: @escaping @MainActor (CmuxNextDaemon.JSONValue) -> Void) async throws -> UInt64 {
            idle.begin()
            defer { idle.end() }
            open()
            next += 1
            listeners[next] = (event, onEvent, false)
            idle.begin()
            return next
        }

        func pauseListener(_ id: UInt64) {
            guard listeners[id]?.paused == false else { return }
            listeners[id]?.paused = true
            idle.end()
        }

        func resumeListener(_ id: UInt64) {
            guard listeners[id]?.paused == true else { return }
            listeners[id]?.paused = false
            idle.begin()
        }

        func stopListener(_ id: UInt64) {
            guard let listener = listeners.removeValue(forKey: id) else { return }
            if !listener.paused { idle.end() }
        }

        /// A call on the relay connection (``PageRelayChannel/send(operation:params:idempotencyKey:context:)``).
        func call() async {
            idle.begin()
            defer { idle.end() }
            open()
            await Task.yield()
        }

        /// The relay connection: opened on a use while none is open.
        private func open() {
            guard clients == 0 else { return }
            clients = 1
            opened += 1
        }

        func publish(_ event: String) {
            for listener in listeners.values where listener.event == event && !listener.paused {
                listener.deliver(.object(["n": .number(1)]))
            }
        }

        /// Live listeners (paused ones hear nothing).
        var listening: Int { listeners.values.filter { !$0.paused }.count }
        /// Every listener, paused or live.
        var total: Int { listeners.count }
    }

    /// A provider whose streams are ``PageRelayStreams`` on a fake channel, as ``DaemonPageRelay``.
    @MainActor final class RelayProvider: PageProvider {
        let channel: FakeRelayChannel
        let streams = PageRelayStreams()
        private(set) var freezes = 0
        private(set) var thaws = 0

        init(channel: FakeRelayChannel) { self.channel = channel }

        func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
            await channel.call()
            return .object([:])
        }

        func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
            let event = stream.dropFirst("cmux.".count).replacingOccurrences(of: ".", with: "-")
            let listener = try await channel.listen(event: event) { payload in
                onEvent((try? DaemonPageRelay.pageValue(payload)) ?? .object([:]))
            }
            let stop = streams.add(listener: listener, on: channel) { onEvent(["resync": true]) }
            return DaemonPageRelay.subscription(onCancel: stop)
        }

        func pageWillFreeze() {
            freezes += 1
            streams.freeze()
        }

        func pageDidThaw() {
            thaws += 1
            streams.thaw()
        }
    }

    static let descriptor = PageDescriptor(id: "cmux.history", resource: "history", processGroup: .solo,
                                           namespaces: ["cmux.history.", "cmux.workspace."])

    /// A router of the History page with the relay serving both its namespaces.
    static func router(_ provider: RelayProvider) -> (PageRouter, Sent) {
        let router = PageRouter(descriptor: descriptor, routes: [
            PageRoute(prefix: "cmux.history.", provider: provider),
            PageRoute(prefix: "cmux.workspace.", provider: provider),
        ])
        let sent = Sent()
        router.send = { sent.envelopes.append($0) }
        return (router, sent)
    }

    /// The envelopes the router sent the page.
    @MainActor final class Sent {
        var envelopes: [CmuxNextSettings.JSONValue] = []
        /// Every event envelope, a batch's included.
        var events: [CmuxNextSettings.JSONValue] {
            envelopes.flatMap { envelope -> [CmuxNextSettings.JSONValue] in
                if envelope["t"]?.stringValue == "evs" { return envelope["events"]?.arrayValue ?? [] }
                return envelope["t"]?.stringValue == "ev" ? [envelope] : []
            }
        }
    }

    static func subscribe(_ router: PageRouter, _ stream: String, id: Int) async throws {
        let reply = await router.handle(["t": "sub", "id": .number(Double(id)), "stream": .string(stream)])
        try #require(reply["t"]?.stringValue == "ok", "\(reply)")
    }

    static func historyList(_ provider: RelayProvider) async throws {
        _ = try await provider.call("cmux.history.list", params: .object([:]), context: PageCallContext(page: "cmux.history"))
    }

    // MARK: Freeze hooks through the router

    /// Each provider hears a freeze once, however many namespaces it serves and however often the
    /// lifecycle asks; the thaw pairs with it.
    @Test func eachProviderHearsOneFreezeAndOneThaw() {
        let provider = RelayProvider(channel: FakeRelayChannel())
        let (router, _) = Self.router(provider)
        router.pageWillFreeze()
        router.pageWillFreeze()
        #expect(provider.freezes == 1)
        #expect(router.providersFrozen)
        router.pageDidThaw()
        router.pageDidThaw()
        #expect(provider.thaws == 1)
        #expect(!router.providersFrozen)
    }

    /// A frozen page that closes (tab closed, reload, discard) ends its streams first, then its
    /// providers hear the thaw, so their freeze and thaw calls pair up and nothing listens again.
    @Test func closingAFrozenPageThawsItsProvidersWithNoStreamLeft() async throws {
        let channel = FakeRelayChannel()
        let provider = RelayProvider(channel: channel)
        let (router, sent) = Self.router(provider)
        try await Self.subscribe(router, "cmux.history.changed", id: 1)
        router.pageWillFreeze()
        router.close()
        #expect(provider.thaws == 1)
        #expect(provider.streams.count == 0)
        #expect(channel.total == 0, "nothing listens for a closed page")
        #expect(sent.events.isEmpty, "a closed page gets no resync")
    }

    // MARK: Listens and resync

    /// Freeze: no stream keeps a live listen. Thaw, in its own turn: each listens again and gets
    /// exactly one `{resync: true}`, which reaches the page with the hold's release.
    @Test func aFrozenPageHoldsNoListenAndResyncsEachStreamOnceOnThaw() async throws {
        let channel = FakeRelayChannel()
        let provider = RelayProvider(channel: channel)
        let (router, sent) = Self.router(provider)
        try await Self.subscribe(router, "cmux.history.changed", id: 1)
        try await Self.subscribe(router, "cmux.workspace.changed", id: 2)
        #expect(channel.listening == 2)

        router.holdDelivery()
        router.pageWillFreeze()
        #expect(channel.listening == 0, "a frozen page keeps no daemon listen")
        channel.publish("history-changed")
        #expect(router.heldEventCount == 0, "no live listen, so nothing arrives to hold")

        router.pageDidThaw()
        #expect(channel.listening == 2)
        #expect(router.heldEventCount == 2, "the resyncs are in the hold before it releases")
        router.releaseDelivery()
        let events = sent.events
        #expect(events.count == 2, "one resync per stream: \(events)")
        #expect(events.allSatisfy { $0["data"]?["resync"]?.boolValue == true })
        #expect(Set(events.compactMap { $0["sub"]?.doubleValue }) == [1, 2])

        channel.publish("history-changed")
        #expect(sent.events.count == 3, "the stream listens again after the thaw")
    }

    /// A stream the page opens while frozen pauses at once and resyncs on the thaw like the others.
    @Test func aStreamAddedWhileFrozenPausesAndResyncs() async throws {
        let channel = FakeRelayChannel()
        let provider = RelayProvider(channel: channel)
        let (router, sent) = Self.router(provider)
        router.pageWillFreeze()
        try await Self.subscribe(router, "cmux.history.changed", id: 1)
        #expect(channel.listening == 0)
        router.pageDidThaw()
        #expect(channel.listening == 1)
        #expect(sent.events.count == 1)
    }

    /// The page ends a stream while frozen: the thaw resumes and resyncs nothing for it.
    @Test func anUnsubscribeWhileFrozenIsNotRestarted() async throws {
        let channel = FakeRelayChannel()
        let provider = RelayProvider(channel: channel)
        let (router, sent) = Self.router(provider)
        try await Self.subscribe(router, "cmux.history.changed", id: 1)
        router.pageWillFreeze()
        _ = await router.handle(["t": "unsub", "sub": 1])
        #expect(channel.total == 0)
        router.pageDidThaw()
        #expect(channel.listening == 0)
        #expect(sent.events.isEmpty)
    }

    // MARK: Idle close

    /// 30 s after the last live listener and call, the channel has no daemon client; a listener or a
    /// call in between keeps it.
    @Test func aChannelClosesItsDaemonClientThirtySecondsAfterItsLastUse() async throws {
        let channel = FakeRelayChannel()
        let provider = RelayProvider(channel: channel)
        let (router, _) = Self.router(provider)
        try await Self.subscribe(router, "cmux.history.changed", id: 1)
        #expect(channel.clients == 1)
        #expect(channel.deadline.armed == nil, "a live listener keeps the connection")

        router.pageWillFreeze()
        #expect(channel.deadline.armed?.delay == PageRelayIdleClose.delay)
        #expect(PageRelayIdleClose.delay == .seconds(30))
        #expect(channel.clients == 1, "the close waits out the idle delay")
        channel.deadline.fire()
        #expect(channel.clients == 0, "0 page-relay clients 30 s after the page froze")

        // The thaw's resync makes the page re-read; that call opens the connection before it reads,
        // and the live listener keeps it.
        router.pageDidThaw()
        #expect(channel.deadline.armed == nil)
        try await Self.historyList(provider)
        #expect(channel.clients == 1)
        #expect(channel.deadline.armed == nil, "a live listener keeps the connection")
        _ = await router.handle(["t": "unsub", "sub": 1])
        #expect(channel.deadline.armed != nil)
        channel.deadline.fire()
        #expect(channel.clients == 0, "0 page-relay clients 30 s after the page ended its stream")

        // A call alone opens a connection again and arms the close when it ends.
        try await Self.historyList(provider)
        #expect(channel.clients == 1)
        #expect(channel.opened == 3)
        #expect(channel.deadline.armed != nil)
        channel.deadline.fire()
        #expect(channel.clients == 0)
    }

    /// A use that starts before the deadline fires cancels it; an action that still runs after a
    /// later use began does nothing.
    @Test func aUseBeforeTheDeadlineKeepsTheConnection() {
        let deadline = ManualDeadline()
        let idle = PageRelayIdleClose(deadline: deadline)
        var closes = 0
        idle.onIdle = { closes += 1 }
        idle.begin()
        idle.end()
        let stale = deadline.armed?.action
        idle.begin()
        #expect(deadline.armed == nil)
        stale?()
        #expect(closes == 0, "the stale wake finds the connection in use")
        idle.end()
        deadline.fire()
        #expect(closes == 1)
        #expect(!idle.inUse)
    }

    // MARK: The page host keeps the channels

    /// One channel per service and daemon page id, kept by the host instance: no static.
    @Test func theHostKeepsOneChannelPerKey() {
        let channels = PageRelayChannels()
        let service = NSObject()
        let key = PageRelayChannels.Key(service: ObjectIdentifier(service), page: "history")
        let first = channels.channel(for: key) { NSObject() }
        let again = channels.channel(for: key) { NSObject() }
        #expect(first === again)
        _ = channels.channel(for: PageRelayChannels.Key(service: ObjectIdentifier(service), page: "settings")) { NSObject() }
        #expect(channels.count == 2)
        #expect(PageRelayChannels().count == 0, "another host has its own")
    }

    /// The daemon page id of a descriptor id is unchanged by the move into the host.
    @Test func relayPageIDs() {
        #expect(PageRelayChannel.relayPageID("cmux.history") == "history")
        #expect(PageRelayChannel.relayPageID("cmux.Bad") == nil)
    }
}
