@testable import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneSourceIconRecoveryTests {
    private actor Resolver: RemoteAddressResolving {
        let addresses: [RemoteAddress]
        var requests: [String] = []
        var fails = false
        func setFailure(_ fails: Bool) { self.fails = fails }
        init(_ addresses: [RemoteAddress] = [.v4([93, 184, 216, 34])]) { self.addresses = addresses }
        func resolve(_ host: String) async throws -> [RemoteAddress] {
            requests.append(host)
            if fails { throw URLError(.cannotFindHost) }
            return addresses
        }
    }
    private actor Transport: RemoteFetchTransport {
        let clock: SourceIconTestClock
        var requests: [RemoteFetchRequest] = []
        var bodies: [String] = []
        var statuses: [Int] = []
        var connectFailures = 0
        var advances: [Duration] = []
        var hold = false
        var holdIndex: Int?
        var fail = false
        let starts: AsyncStream<String>
        private let events: AsyncStream<String>.Continuation
        var pending: CheckedContinuation<RemoteFetchResponse, any Error>?

        init(clock: SourceIconTestClock) {
            self.clock = clock
            (starts, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(32))
        }
        func configure(_ bodies: [String], statuses: [Int] = [], connectFailures: Int = 0, advances: [Duration] = [], hold: Bool = false, holdIndex: Int? = nil, fail: Bool = false) {
            self.statuses = statuses; self.connectFailures = connectFailures
            self.bodies = bodies; self.advances = advances; self.hold = hold; self.holdIndex = holdIndex; self.fail = fail
        }
        func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
            requests.append(request)
            if connectFailures > 0 {
                connectFailures -= 1
                throw PinnedTLSTransport.ConnectFailure(underlying: URLError(.cannotConnectToHost))
            }
            if fail { throw URLError(.cannotConnectToHost) }
            if !advances.isEmpty { clock.advance(by: advances.removeFirst()) }
            if hold || requests.count - 1 == holdIndex {
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { continuation in
                        pending = continuation
                        events.yield(request.target)
                    }
                } onCancel: { Task { await self.cancel() } }
            }
            events.yield(request.target)
            let status = statuses.isEmpty ? 200 : statuses.removeFirst()
            let body = bodies.isEmpty ? "" : bodies.removeFirst()
            // Exercise the pinned transport's actual HTTP reader as well as guarded status handling.
            var reader = RemoteFetchReplyReader(maximumBody: maximumBytes, allowsTruncation: request.allowsTruncation)
            let wire = "HTTP/1.1 \(status) Test\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            _ = try reader.append(Data(wire.utf8))
            return try reader.finish()
        }
        func cancel() { pending?.resume(throwing: CancellationError()); pending = nil; events.yield("cancelled") }
        func release() {
            pending?.resume(returning: RemoteFetchResponse(status: 200, headers: [:], body: Data("image".utf8)))
            pending = nil; hold = false
        }
    }

    private func loader(_ transport: Transport, clock: SourceIconTestClock, capacity: Int = 256, queued: Int = 0) -> AgentPaneSourceIcons {
        AgentPaneSourceIcons(maximumConcurrent: 1, maximumQueued: queued, maximumCached: capacity,
            fetch: GuardedRemoteFetch(maximumBytes: 1 << 20, timeout: .seconds(10), accept: GuardedRemoteFetch.imageAccept,
                resolver: Resolver(), transport: transport, clock: clock),
            decode: { $0 == Data("image".utf8) ? $0 : nil })
    }
    private func url(_ host: String = "site", _ path: String = "/favicon.ico") -> URL { URL(string: "https://\(host).example\(path)")! }

    @Test func fallbackNeverRetriesTheICOAndKeepsBothCandidateOpportunities() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["bad", "<link rel=icon href=/favicon.ico><link rel=icon href=/favicon.ico#again><link rel=icon href=/a.png><link rel=icon href=/b.png>", "bad", "image"])
        #expect(await loader(transport, clock: clock).data(at: url()) == Data("image".utf8))
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/", "/a.png", "/b.png"])
    }

    @Test func aRedirectCannotFetchAnAlreadyTriedURLAgain() async throws {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["image", "image"])
        let chain = AgentPaneSourceIconTransport(transport)
        let request = RemoteFetchRequest(address: .v4([93, 184, 216, 34]), host: "site.example", port: 443,
            target: "/favicon.ico", headers: [:])
        _ = try await chain.send(request, maximumBytes: 1024)
        // DNS may choose a different checked address on a redirect back to the same URL.
        let redirected = RemoteFetchRequest(address: .v4([93, 184, 216, 35]), host: "site.example", port: 443,
            target: "/favicon.ico", headers: [:])
        do {
            _ = try await chain.send(redirected, maximumBytes: 1024)
            Issue.record("a repeated URL reached the chain transport")
        } catch { #expect(error is CancellationError) }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [403, 404, 410, 429, 503]) func errorStatusIsObservableWithoutWaitingForItsBody(status: Int) throws {
        for truncation in [false, true] {
            var reader = RemoteFetchReplyReader(maximumBody: 16, allowsTruncation: truncation)
            // Error pages may declare a huge or compressed body. Only the HTTP answer is needed.
            let wire = "HTTP/1.1 \(status) Test\r\nContent-Length: 999999\r\nContent-Encoding: gzip\r\n\r\n"
            #expect(try reader.append(Data(wire.utf8)))
            let response = try reader.finish()
            #expect(response.status == status)
            #expect(response.body.isEmpty)
        }
    }

    @Test func failedConnectionFallsBackToTheNextCheckedAddressAndDecodes() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["image"], connectFailures: 1)
        let addresses: [RemoteAddress] = [.v4([93, 184, 216, 34]), .v4([93, 184, 216, 35])]
        let icons = AgentPaneSourceIcons(fetch: GuardedRemoteFetch(maximumBytes: 1024, timeout: .seconds(10),
            accept: GuardedRemoteFetch.imageAccept, resolver: Resolver(addresses), transport: transport, clock: clock),
            decode: { $0 == Data("image".utf8) ? $0 : nil })
        #expect(await icons.result(at: url()) == .icon(Data("image".utf8)))
        #expect(await transport.requests.map(\.address) == addresses)
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/favicon.ico"])
    }

    @Test func icoTimeoutAndAnsweredHomeWithoutIconsIsTemporaryAndNotCached() async throws {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["<head></head>"], holdIndex: 0)
        let icons = loader(transport, clock: clock)
        let reader = Task { await icons.result(at: url()) }
        var starts = await transport.starts.makeAsyncIterator()
        #expect(await starts.next() == "/favicon.ico")
        var sleeps = clock.sleeps.makeAsyncIterator()
        #expect(await sleeps.next() == .seconds(10))
        clock.advance(by: .seconds(10))
        #expect(await reader.value == .temporary)
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/"])
        await transport.configure(["image"])
        #expect(await icons.result(at: url()) == .icon(Data("image".utf8)))
        #expect(await transport.requests.count == 3)
    }

    @Test(arguments: [403, 404, 410]) func ico404AndAnsweredHomeIsAGenuineCachedMiss(status: Int) async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["", ""], statuses: [404, status])
        let icons = loader(transport, clock: clock)
        #expect(await icons.result(at: url()) == .unavailable)
        #expect(await icons.result(at: url()) == .unavailable)
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/"])
    }

    @Test(arguments: [404, 429, 503]) func candidateHTTPStatusDeterminesWhetherAMissIsCached(status: Int) async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["", "<link rel=icon href=/icon.png>", ""], statuses: [404, 200, status])
        let icons = loader(transport, clock: clock)
        let expected: AgentPaneSourceIconResult = status == 404 ? .unavailable : .temporary
        #expect(await icons.result(at: url()) == expected)
        await transport.configure(["image"])
        #expect(await icons.result(at: url()) == (status == 404 ? .unavailable : .icon(Data("image".utf8))))
        #expect(await transport.requests.count == (status == 404 ? 3 : 4))
    }

    @Test(arguments: [429, 503]) func transientICOOrHomeStatusIsNotCached(status: Int) async {
        for statuses in [[status, 200], [404, status]] {
            let clock = SourceIconTestClock()
            let transport = Transport(clock: clock)
            await transport.configure(["", "<head></head>"], statuses: statuses)
            let icons = loader(transport, clock: clock)
            #expect(await icons.result(at: url()) == .temporary)
            await transport.configure(["image"])
            #expect(await icons.result(at: url()) == .icon(Data("image".utf8)))
            #expect(await transport.requests.count == 3)
        }
    }

    @Test func aBlockedCandidateIsAGenuineMiss() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["", "<link rel=icon href='https://127.0.0.1/icon.png'>"], statuses: [404, 200])
        #expect(await loader(transport, clock: clock).result(at: url()) == .unavailable)
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/"])
    }

    @Test func aFailedDNSLookupIsTemporaryAndNotCached() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        let resolver = Resolver()
        await resolver.setFailure(true)
        let icons = AgentPaneSourceIcons(fetch: GuardedRemoteFetch(maximumBytes: 1024, timeout: .seconds(10),
            accept: GuardedRemoteFetch.imageAccept, resolver: resolver, transport: transport, clock: clock),
            decode: { $0 == Data("image".utf8) ? $0 : nil })
        #expect(await icons.result(at: url()) == .temporary)
        #expect(await transport.requests.isEmpty)
        await resolver.setFailure(false)
        await transport.configure(["image"])
        #expect(await icons.result(at: url()) == .icon(Data("image".utf8)))
        #expect(await resolver.requests.count == 3)
        #expect(await transport.requests.count == 1)
    }

    @MainActor @Test func panesWiredFromTheSameServicesShareOneOriginQueue() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["image"])
        let services = AgentPaneReplyServices(sourceIcons: loader(transport, clock: clock))
        let first = AgentPaneModel(host: NoHost())
        let second = AgentPaneModel(host: NoHost())
        services.wire(first.replyLinks)
        services.wire(second.replyLinks)
        #expect(await first.replyLinks.favicon(url("shared", "/one")) == .icon(Data("image".utf8)))
        #expect(await second.replyLinks.favicon(url("shared", "/two")) == .icon(Data("image".utf8)))
        #expect(await transport.requests.map(\.target) == ["/favicon.ico"])
    }

    @Test func aBlockedResolvedAddressIsAGenuineCachedMiss() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        let resolver = Resolver([.v4([127, 0, 0, 1])])
        let icons = AgentPaneSourceIcons(fetch: GuardedRemoteFetch(maximumBytes: 1024, timeout: .seconds(10),
            accept: GuardedRemoteFetch.imageAccept, resolver: resolver, transport: transport, clock: clock))
        #expect(await icons.result(at: url()) == .unavailable)
        #expect(await icons.result(at: url()) == .unavailable)
        #expect(await resolver.requests == ["site.example", "site.example"])
        #expect(await transport.requests.isEmpty)
    }

    @Test func aDecodedCandidateWinsOverAnEarlierTransientHTTPStatus() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["", "<link rel=icon href=/icon.png>", "image"], statuses: [503, 200, 200])
        #expect(await loader(transport, clock: clock).result(at: url()) == .icon(Data("image".utf8)))
    }

    @Test func totalDeadlineStopsTheChainAtTwelveSeconds() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        let icons = loader(transport, clock: clock)
        // Advancing beyond the deadline inside a response also checks that no candidate starts.
        await transport.configure(["bad", "<link rel=icon href=/a.png>"], advances: [.seconds(8), .seconds(5)])
        #expect(await icons.result(at: url()) == .temporary)
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/"])
    }

    @Test func heldTransportIsCancelledByTheRemainingChainDeadline() async throws {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["bad"], advances: [.seconds(8)], holdIndex: 1)
        let icons = loader(transport, clock: clock)
        let reader = Task { await icons.result(at: url()) }
        var starts = await transport.starts.makeAsyncIterator()
        #expect(await starts.next() == "/favicon.ico")
        #expect(await starts.next() == "/")
        var sleeps = clock.sleeps.makeAsyncIterator()
        let first = try #require(await sleeps.next())
        let second = try #require(await sleeps.next())
        #expect(Set([first, second]) == Set([.seconds(10), .seconds(12)]))
        clock.advance(by: .seconds(4))
        #expect(await reader.value == .temporary)
        #expect(await starts.next() == "cancelled")
        #expect(await transport.requests.count == 2)
    }

    @Test func completedIconsShareOriginsExpireAndEvictLeastRecentlyUsed() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(Array(repeating: "image", count: 8))
        let icons = loader(transport, clock: clock, capacity: 2)
        #expect(await icons.data(at: url("a")) != nil)
        #expect(await icons.data(at: url("b")) != nil)
        #expect(await icons.data(at: url("a", "/another/path?q=private")) != nil)
        #expect(await transport.requests.count == 2)
        #expect(await icons.data(at: url("c")) != nil)
        #expect(await icons.data(at: url("a")) != nil)
        #expect(await transport.requests.count == 3)
        #expect(await icons.data(at: url("b")) != nil)
        #expect(await transport.requests.count == 4)
        clock.advance(by: .seconds(6 * 60 * 60))
        #expect(await icons.data(at: url("b")) != nil)
        #expect(await transport.requests.count == 5)
    }

    @Test func genuineMissIsCachedForTenMinutes() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure(["bad", "<head></head>", "image"])
        let icons = loader(transport, clock: clock)
        #expect(await icons.result(at: url()) == .unavailable)
        #expect(await icons.result(at: url()) == .unavailable)
        #expect(await transport.requests.count == 2)
        clock.advance(by: .seconds(10 * 60))
        #expect(await icons.result(at: url()) == .icon(Data("image".utf8)))
        #expect(await transport.requests.count == 3)
    }

    @Test func aFailedTransportIsNotCachedAsAGenuineMiss() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure([], fail: true)
        let icons = loader(transport, clock: clock)
        #expect(await icons.result(at: url()) == .temporary)
        await transport.configure(["image"])
        #expect(await icons.result(at: url()) == .icon(Data("image".utf8)))
        #expect(await transport.requests.count == 3)
    }

    @Test func overloadAndCancellationAreTemporaryAndNeverPoisonTheCache() async {
        let clock = SourceIconTestClock()
        let transport = Transport(clock: clock)
        await transport.configure([], hold: true)
        let icons = loader(transport, clock: clock, queued: 1)
        let id = UUID()
        let active = await icons.requestResult(at: url("active"), id: id)
        var starts = await transport.starts.makeAsyncIterator()
        _ = await starts.next()
        let queued = await icons.requestResult(at: url("queued"), id: UUID())
        #expect(await icons.result(at: url("overflow")) == .temporary)
        await icons.cancel(at: url("active"), id: id)
        #expect(await active.value == .temporary)
        #expect(await starts.next() == "cancelled")
        #expect(await starts.next() == "/favicon.ico")
        await transport.release()
        #expect(await queued.value == .icon(Data("image".utf8)))
        await transport.configure(["image", "image"])
        #expect(await icons.result(at: url("active")) == .icon(Data("image".utf8)))
        #expect(await icons.result(at: url("overflow")) == .icon(Data("image".utf8)))
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
    @MainActor @Test func pageReplyDistinguishesTemporaryFromNoIcon() async {
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.sourceIconsBaseline = true
        model.replyLinks.favicon = { _ in .temporary }
        let temporary = await model.respond(to: .favicon(url()))
        #expect((temporary["value"] as? [String: Any])?["temporary"] as? Bool == true)
        model.replyLinks.favicon = { _ in .unavailable }
        let missing = await model.respond(to: .favicon(url()))
        #expect((missing["value"] as? [String: Any])?["temporary"] == nil)
    }
}
