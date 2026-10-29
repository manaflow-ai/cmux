@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// Provider freeze hooks and the page relay channels, on the production
/// ``DaemonPageRelay`` and ``PageRelayChannel`` over a fake daemon socket that counts its open
/// `page_relay` connections: a frozen page's relay holds no live listen, its channel closes its
/// daemon connection 30 s after the last listener and call, a thaw gives each stream one resync,
/// and the next call opens the connection again.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct PageRelayChannelFreezeTests {
    /// The idle close's deadline, fired by the test.
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

    /// The daemon service a channel needs: an unstarted main connection (no gesture call here asks
    /// it for a token), `origin-claim-v1`, and the fake socket for the relay connections.
    @MainActor final class FakeRelayDaemon: PageRelayDaemon {
        let connection: DaemonConnection? = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cnp-relay-main.sock"))
        let endpointProvider: DaemonConnection.EndpointProvider?
        let retryWake = RetryWake(owner: "test.page-relay")

        init(socket: String) {
            endpointProvider = { DaemonEndpoint(socketPath: socket) }
        }

        func supports(_ capability: String) -> Bool { capability == DaemonClientRole.originClaimCapability }
    }

    /// The envelopes a router sent its page, with a wait for the next ones.
    @MainActor final class Sent {
        private(set) var envelopes: [CmuxNextSettings.JSONValue] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func append(_ envelope: CmuxNextSettings.JSONValue) {
            envelopes.append(envelope)
            let count = events.count
            let ready = waiters.filter { $0.count <= count }
            waiters.removeAll { $0.count <= count }
            for waiter in ready { waiter.continuation.resume() }
        }

        /// Every event envelope, a batch's included.
        var events: [CmuxNextSettings.JSONValue] {
            envelopes.flatMap { envelope -> [CmuxNextSettings.JSONValue] in
                if envelope["t"]?.stringValue == "evs" { return envelope["events"]?.arrayValue ?? [] }
                return envelope["t"]?.stringValue == "ev" ? [envelope] : []
            }
        }

        /// Returns once the page got `count` events.
        func waitForEvents(_ count: Int) async {
            guard events.count < count else { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    /// One History page: a router whose `cmux.history.` and `cmux.workspace.` routes go to its own
    /// production relay, on the channels the pages share.
    @MainActor struct Page {
        let router: PageRouter
        let relay: DaemonPageRelay
        let sent: Sent
    }

    /// The fake socket, the shared channels and the idle deadline of every channel made.
    @MainActor struct Rig {
        let socket: FakePageRelaySocket
        let daemon: FakeRelayDaemon
        let channels = PageRelayChannels()
        let work = BackgroundWork(label: "test.page-relay")
        let deadline = ManualDeadline()

        init() throws {
            socket = try FakePageRelaySocket()
            daemon = FakeRelayDaemon(socket: socket.path)
        }

        /// Ends the socket; the daemon lives until here, as the app's outlives its pages' relays.
        func stop() {
            withExtendedLifetime(daemon) { socket.stop() }
        }

        func page() -> Page {
            let deadline = deadline
            let relay = DaemonPageRelay(daemon: daemon, channels: channels, work: work) { deadline }
            let router = PageRouter(descriptor: PageRelayChannelFreezeTests.descriptor, routes: [
                PageRoute(prefix: "cmux.history.", provider: relay),
                PageRoute(prefix: "cmux.workspace.", provider: relay),
            ])
            let sent = Sent()
            router.send = { sent.append($0) }
            return Page(router: router, relay: relay, sent: sent)
        }
    }

    static let descriptor = PageDescriptor(id: "cmux.history", resource: "history", processGroup: .solo,
                                           namespaces: ["cmux.history.", "cmux.workspace."])

    static func subscribe(_ page: Page, _ stream: String, id: Int) async throws {
        let reply = await page.router.handle(["t": "sub", "id": .number(Double(id)), "stream": .string(stream)])
        try #require(reply["t"]?.stringValue == "ok", "\(reply)")
    }

    static func historyList(_ page: Page) async throws {
        let result = try await page.relay.call("cmux.history.list", params: .object([:]), context: PageCallContext(page: "cmux.history"))
        #expect(result["entries"]?.arrayValue?.isEmpty == true, "\(result)")
    }

    // MARK: Freeze, idle close and thaw on the production channel

    /// Two History tabs share one channel. One freezes: its listener hears nothing while the other
    /// still does. Once the other ends its stream, 30 s later the daemon has no page-relay client.
    /// The thaw resumes the frozen tab's listener and sends it one resync in the thaw's turn; its
    /// re-read opens one connection again, and the resumed listener hears the next event.
    @Test func aFrozenPageClosesItsRelayConnectionWhenIdleAndReopensOnThaw() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let frozen = rig.page()
        let other = rig.page()
        try await Self.subscribe(frozen, "cmux.history.changed", id: 1)
        try await Self.subscribe(other, "cmux.history.changed", id: 1)
        #expect(rig.channels.count == 1, "both tabs use the one History channel")
        #expect(rig.socket.opened == 1)
        #expect(rig.deadline.armed == nil, "live listeners keep the connection")

        rig.socket.publish("history-changed")
        await frozen.sent.waitForEvents(1)
        await other.sent.waitForEvents(1)

        frozen.router.pageWillFreeze()
        #expect(rig.deadline.armed == nil, "the other tab's live listener keeps the connection")
        rig.socket.publish("history-changed")
        // Both listeners hear the same daemon line in one pass: the live one got it, so the paused one never will.
        await other.sent.waitForEvents(2)
        #expect(frozen.sent.events.count == 1, "a paused listener hears nothing")

        _ = await other.router.handle(["t": "unsub", "sub": 1])
        #expect(rig.deadline.armed?.delay == PageRelayIdleClose.delay)
        #expect(PageRelayIdleClose.delay == .seconds(30))
        #expect(rig.socket.openNow == 1, "the close waits out the idle delay")
        rig.deadline.fire()
        await rig.socket.waitUntil(open: 0)
        #expect(rig.socket.openNow == 0, "0 page-relay daemon clients 30 s after the last live listener")

        frozen.router.holdDelivery()
        frozen.router.pageDidThaw()
        #expect(frozen.router.heldEventCount == 1, "the resync is in the hold before it releases")
        frozen.router.releaseDelivery()
        let resync = try #require(frozen.sent.events.last)
        #expect(resync["data"]?["resync"]?.boolValue == true, "\(resync)")
        #expect(frozen.sent.events.count == 2, "one resync for the one stream")
        #expect(rig.deadline.armed == nil, "the resumed listener keeps the connection")

        // The page's re-read after the resync opens the connection again.
        try await Self.historyList(frozen)
        #expect(rig.socket.opened == 2)
        #expect(rig.socket.openNow == 1)
        rig.socket.publish("history-changed")
        await frozen.sent.waitForEvents(3)
        #expect(other.sent.events.count == 2, "the ended stream hears nothing")
    }

    /// A frozen page whose document reloads (a commit or a crash reload resets its router) is
    /// still frozen: the new document's streams start paused, so 30 s later the daemon has no
    /// page-relay client; the thaw resumes them with one resync each.
    @Test func aStreamOfAFrozenPagesNewDocumentStartsPaused() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await Self.subscribe(page, "cmux.history.changed", id: 1)
        page.router.pageWillFreeze()
        page.router.reset()
        #expect(page.router.providersFrozen, "a new document does not thaw the providers")

        try await Self.subscribe(page, "cmux.history.changed", id: 1)
        #expect(rig.deadline.armed?.delay == PageRelayIdleClose.delay, "the new document's listener started paused")
        rig.deadline.fire()
        await rig.socket.waitUntil(open: 0)
        #expect(rig.socket.openNow == 0)

        page.router.pageDidThaw()
        let events = page.sent.events
        #expect(events.count == 1, "one resync for the new document's one stream: \(events)")
        #expect(events.first?["data"]?["resync"]?.boolValue == true)
        try await Self.historyList(page)
        rig.socket.publish("history-changed")
        await page.sent.waitForEvents(2)
    }

    /// A stream the page opens while frozen pauses at once; the page ends another while frozen,
    /// and the thaw restarts nothing for it.
    @Test func streamsAddedOrEndedWhileFrozen() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await Self.subscribe(page, "cmux.history.changed", id: 1)
        page.router.pageWillFreeze()
        try await Self.subscribe(page, "cmux.workspace.changed", id: 2)
        _ = await page.router.handle(["t": "unsub", "sub": 1])
        #expect(rig.deadline.armed != nil, "no live listener keeps the connection")

        page.router.pageDidThaw()
        let events = page.sent.events
        #expect(events.count == 1, "\(events)")
        #expect(events.first?["sub"]?.doubleValue == 2)
        #expect(rig.deadline.armed == nil)
    }

    /// A call alone opens a connection and arms the close when it ends; the close then leaves the
    /// daemon with no page-relay client, and the next call opens one again.
    @Test func aCallAloneHoldsTheConnectionOnlyUntilIdle() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await Self.historyList(page)
        #expect(rig.socket.openNow == 1)
        #expect(rig.deadline.armed?.delay == PageRelayIdleClose.delay)
        rig.deadline.fire()
        await rig.socket.waitUntil(open: 0)
        try await Self.historyList(page)
        #expect(rig.socket.opened == 2)
        #expect(rig.socket.openNow == 1)
    }

    /// Closing a frozen page (tab closed, discarded) ends its streams, then thaws its providers:
    /// nothing listens for it again and it gets no resync.
    @Test func closingAFrozenPageEndsItsListensWithNoResync() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        try await Self.subscribe(page, "cmux.history.changed", id: 1)
        page.router.pageWillFreeze()
        page.router.close()
        #expect(!page.router.providersFrozen)
        #expect(page.sent.events.isEmpty, "a closed page gets no resync")
        #expect(rig.deadline.armed != nil)
        rig.deadline.fire()
        await rig.socket.waitUntil(open: 0)
    }

    // MARK: Router hooks and the idle close itself

    /// Each provider hears a freeze once, however many namespaces it serves and however often the
    /// lifecycle asks; the thaw pairs with it.
    @Test func eachProviderHearsOneFreezeAndOneThaw() {
        let counter = HookCounter()
        let router = PageRouter(descriptor: Self.descriptor, routes: [
            PageRoute(prefix: "cmux.history.", provider: counter),
            PageRoute(prefix: "cmux.workspace.", provider: counter),
        ])
        router.pageWillFreeze()
        router.pageWillFreeze()
        #expect(counter.freezes == 1)
        #expect(router.providersFrozen)
        router.reset()
        #expect(counter.thaws == 0, "a new document leaves the providers frozen")
        router.pageDidThaw()
        router.pageDidThaw()
        #expect(counter.thaws == 1)
        #expect(!router.providersFrozen)
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

    /// Counts the freeze hooks the router gives it.
    @MainActor final class HookCounter: PageProvider {
        private(set) var freezes = 0
        private(set) var thaws = 0

        func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
            .object([:])
        }

        func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
            PageSubscription(frozenDelivery: .resync) {}
        }

        func pageWillFreeze() { freezes += 1 }
        func pageDidThaw() { thaws += 1 }
    }
}

/// A Unix socket served by this test process that speaks just enough of the page relay's protocol:
/// `identify` (with `origin-claim-v1` and `page-router-v1`), `client-hello` naming the
/// `history-changed` and `workspace-changed` events, `subscribe`, and every `cmux.protocol/2`
/// request answered `{entries: []}`. It counts the connections opened and open now, and sends an
/// event line to every open one on ``publish(_:)``.
nonisolated final class FakePageRelaySocket: Sendable {
    let path: String
    private let listener: Int32
    private let state = Mutex(State())

    nonisolated private struct State {
        var clients: Set<Int32> = []
        var opened = 0
        var waits: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    init() throws {
        path = "/tmp/cnp-relay-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        let thread = Thread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                state.withLock {
                    $0.clients.insert(client)
                    $0.opened += 1
                }
                let serving = Thread { [self] in serve(client) }
                serving.qualityOfService = .utility
                serving.start()
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Connections accepted so far.
    var opened: Int { state.withLock { $0.opened } }
    /// Connections open now.
    var openNow: Int { state.withLock { $0.clients.count } }

    /// Returns once exactly `open` connections are open.
    func waitUntil(open target: Int) async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                guard state.clients.count != target else { return true }
                state.waits.append((target, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Sends `{"event": name}` to every open connection.
    func publish(_ name: String) {
        let clients = state.withLock { $0.clients }
        for client in clients { _ = Self.send(["event": name], to: client) }
    }

    /// Sends `line`, a whole subscribe-stream event as the daemon writes it, to every open connection.
    func publish(line: [String: Any]) {
        let clients = state.withLock { $0.clients }
        for client in clients { _ = Self.send(line, to: client) }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private func serve(_ client: Int32) {
        defer { ended(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                guard Self.answer(request, to: client) else { return }
            }
        }
    }

    /// The connection ended: it is no longer open, and the waits it satisfies return.
    private func ended(_ client: Int32) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.clients.remove(client)
            let open = state.clients.count
            let ready = state.waits.filter { $0.count == open }.map(\.continuation)
            state.waits.removeAll { $0.count == open }
            return ready
        }
        close(client)
        for continuation in ready { continuation.resume() }
    }

    private static func answer(_ request: [String: Any], to client: Int32) -> Bool {
        if request["protocol"] as? String == "cmux.protocol/2", let id = request["id"] as? String {
            return send(["protocol": "cmux.protocol/2", "type": "response", "id": id, "ok": true, "result": ["entries": [Any]()]],
                        to: client)
        }
        guard let id = request["id"] as? Int, let command = request["cmd"] as? String else { return true }
        switch command {
        case "identify":
            let identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "gen-relay",
                                           "capabilities": [DaemonClientRole.originClaimCapability, DaemonClientRole.pageRouterCapability]]
            return reply(id, data: identity, to: client)
        case "client-hello":
            return reply(id, data: ["connection_id": "conn-\(client)", "page_events": ["history-changed", "workspace-changed"]], to: client)
        default:
            return reply(id, data: [String: Any](), to: client)
        }
    }

    private static func reply(_ id: Int, data: [String: Any], to client: Int32) -> Bool {
        send(["id": id, "ok": true, "data": data], to: client)
    }

    /// Writes `object` and its newline whole.
    private static func send(_ object: [String: Any], to client: Int32) -> Bool {
        guard var bytes = try? JSONSerialization.data(withJSONObject: object) else { return false }
        bytes.append(0x0A)
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base + offset, raw.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
