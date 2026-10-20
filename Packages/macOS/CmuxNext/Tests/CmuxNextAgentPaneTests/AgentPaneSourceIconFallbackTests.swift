@testable import CmuxNextAgentPane
@testable import CmuxNextPages
@testable import CmuxNextRemoteFetch
import Foundation
import Testing

struct AgentPaneSourceIconFallbackTests {
    private actor Resolver: RemoteAddressResolving {
        let refuseFirstLookup: Bool
        var calls = 0

        init(refuseFirstLookup: Bool = false) { self.refuseFirstLookup = refuseFirstLookup }

        func resolve(_ host: String) async throws -> [RemoteAddress] {
            calls += 1
            return host == "private.example" || (refuseFirstLookup && calls == 1)
                ? [.v4([127, 0, 0, 1])] : [.v4([93, 184, 216, 34])]
        }
    }

    private actor Transport: RemoteFetchTransport {
        let replies: [RemoteFetchResponse]
        let holdIndex: Int?
        let events: AsyncStream<String>.Continuation
        var requests: [RemoteFetchRequest] = []
        var caps: [Int] = []
        var pending: CheckedContinuation<RemoteFetchResponse, any Error>?
        var cancelled = false

        init(_ replies: [RemoteFetchResponse], holdIndex: Int? = nil, events: AsyncStream<String>.Continuation) {
            self.replies = replies
            self.holdIndex = holdIndex
            self.events = events
        }

        func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
            let index = requests.count
            requests.append(request)
            caps.append(maximumBytes)
            if index == holdIndex {
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { continuation in
                        pending = continuation
                        events.yield("held")
                    }
                } onCancel: {
                    // task-owner: transport cancellation completes the held test request.
                    Task { await self.cancel() }
                }
            }
            guard index < replies.count else { throw CancellationError() }
            return replies[index]
        }

        func cancel() {
            cancelled = true
            pending?.resume(throwing: CancellationError())
            pending = nil
            events.yield("cancelled")
        }

        func release() {
            pending?.resume(returning: replies[requests.count - 1])
            pending = nil
        }
    }

    private func reply(_ status: Int = 200, _ body: String = "", headers: [String: String] = [:]) -> RemoteFetchResponse {
        RemoteFetchResponse(status: status, headers: headers, body: Data(body.utf8))
    }

    private func loader(_ transport: Transport, concurrent: Int = 4, queued: Int = 128,
                        resolver: Resolver = Resolver(), clock: SourceIconTestClock = SourceIconTestClock()) -> AgentPaneSourceIcons {
        AgentPaneSourceIcons(maximumConcurrent: concurrent, maximumQueued: queued,
                             fetch: GuardedRemoteFetch(maximumBytes: 1 << 20, timeout: .seconds(10),
                                                       accept: GuardedRemoteFetch.imageAccept,
                                                       resolver: resolver, transport: transport, clock: clock),
                             decode: { $0 == Data("image".utf8) ? $0 : nil })
    }

    @Test(arguments: [404, 200]) func missingOrCorruptICOUsesPageAndCDNWithHTMLHeadersAndBound(_ icoStatus: Int) async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(icoStatus, "corrupt"), reply(200, "<link rel=icon sizes=32x32 href=https://cdn.example/icon.png>"), reply(200, "image")], events: events)
        let url = try #require(URL(string: "https://news.example:8443/favicon.ico"))
        #expect(await loader(transport).data(at: url) == Data("image".utf8))
        let requests = await transport.requests
        #expect(requests.map(\.target) == ["/favicon.ico", "/", "/icon.png"])
        #expect(requests.map(\.host) == ["news.example", "news.example", "cdn.example"])
        #expect(requests[1].port == 8443)
        #expect(requests[1].headers["Accept"] == GuardedRemoteFetch.htmlAccept)
        #expect(requests[1].headers["Accept-Encoding"] == "identity")
        #expect(await transport.caps == [1 << 20, 256 * 1024, 1 << 20])
        #expect(requests.allSatisfy { $0.headers["Cookie"] == nil && $0.headers["Authorization"] == nil })
    }

    @Test func icoRedirectToHomeReusesHTMLForDiscovery() async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(302, headers: ["location": "/"]),
            reply(200, "<link rel=icon href=/mark.png>", headers: ["content-type": "text/html; charset=utf-8"]),
            reply(200, "image")], events: events)
        let url = try #require(URL(string: "https://source.example/favicon.ico"))
        #expect(await loader(transport).data(at: url) == Data("image".utf8))
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/", "/mark.png"])
        #expect(await transport.caps == [1 << 20, 1 << 20, 1 << 20])
    }

    @Test func workingICOSkipsHTML() async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(200, "image")], events: events)
        let url = try #require(URL(string: "https://source.example/favicon.ico"))
        #expect(await loader(transport).data(at: url) == Data("image".utf8))
        #expect(await transport.requests.count == 1)
    }

    @Test func refusedICOStillChecksHomeAndCandidateAddresses() async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(200, "<link rel=icon href=/mark.png>"), reply(200, "image")], events: events)
        let url = try #require(URL(string: "https://source.example/favicon.ico"))
        let icons = loader(transport, resolver: Resolver(refuseFirstLookup: true))
        #expect(await icons.data(at: url) == Data("image".utf8))
        #expect(await transport.requests.map(\.target) == ["/", "/mark.png"])
        #expect(await transport.requests.allSatisfy { $0.address.isPublic })
    }

    @Test(arguments: [403, 404, 500]) func pageFailureStopsChain(_ status: Int) async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(200, "corrupt"), reply(status)], events: events)
        let url = try #require(URL(string: "https://medium.example/favicon.ico"))
        #expect(await loader(transport).data(at: url) == nil)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [false, true]) func onlyTwoDistinctCandidatesAreTried(_ secondWorks: Bool) async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(404), reply(200, "<link rel=icon href=/a.png><link rel=icon href=/a.png><link rel=icon href=/b.png><link rel=icon href=/c.png>"), reply(404), reply(200, secondWorks ? "image" : "bad"), reply(200, "image")], events: events)
        let url = try #require(URL(string: "https://source.example/favicon.ico"))
        #expect(await loader(transport).data(at: url) == (secondWorks ? Data("image".utf8) : nil))
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/", "/a.png", "/b.png"])
    }

    @Test func finalPageURLAndBaseResolveAfterRedirect() async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(404), reply(302, headers: ["location": "https://landing.example/news/"]),
                                   reply(200, "<base href=assets/><link rel=icon href=mark.png>"), reply(200, "image")], events: events)
        let url = try #require(URL(string: "https://source.example/favicon.ico"))
        #expect(await loader(transport).data(at: url) != nil)
        #expect(await transport.requests.last?.host == "landing.example")
        #expect(await transport.requests.last?.target == "/news/assets/mark.png")
    }

    @Test func candidateDNSAndRedirectsStillUseGuard() async throws {
        let (_, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(404), reply(200, "<link rel=icon href=https://private.example/icon.png><link rel=icon href=https://cdn.example/icon.png>"),
                                   reply(302, headers: ["location": "https://127.0.0.1/secret"])], events: events)
        let url = try #require(URL(string: "https://source.example/favicon.ico"))
        #expect(await loader(transport).data(at: url) == nil)
        #expect(await transport.requests.map(\.host) == ["source.example", "source.example", "cdn.example"])
    }

    @Test func duplicatesShareWholeChainAndKeepAdmissionSlot() async throws {
        let (stream, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(404), reply(200, "<link rel=icon href=/mark.png>"), reply(200, "image"), reply(200, "image")], holdIndex: 1, events: events)
        let icons = loader(transport, concurrent: 1, queued: 1)
        let url = try #require(URL(string: "https://same.example/favicon.ico"))
        let firstID = UUID()
        let first = await icons.request(at: url, id: firstID)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == "held")
        let second = await icons.request(at: url, id: UUID())
        let queued = await icons.request(at: URL(string: "https://next.example/favicon.ico")!, id: UUID())
        let overflow = await icons.request(at: URL(string: "https://overflow.example/favicon.ico")!, id: UUID())
        #expect(await overflow.value == nil)
        await icons.cancel(at: url, id: firstID)
        #expect(await first.value == nil)
        #expect(await transport.cancelled == false)
        #expect(await transport.requests.count == 2)
        await transport.release()
        #expect(await second.value == Data("image".utf8))
        #expect(await queued.value == Data("image".utf8))
        #expect(await transport.requests.map(\.target) == ["/favicon.ico", "/", "/mark.png", "/favicon.ico"])
    }

    @Test(arguments: [1, 2]) func lastReaderCancellationCancelsPageOrCandidate(_ held: Int) async throws {
        let (stream, events) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let transport = Transport([reply(404), reply(200, "<link rel=icon href=/mark.png>"), reply(200, "image")], holdIndex: held, events: events)
        let icons = loader(transport)
        let url = try #require(URL(string: "https://source.example/favicon.ico"))
        // task-owner: the test reader; cancellation must reach the current chain transport.
        let reader = Task { await icons.data(at: url) }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == "held")
        reader.cancel()
        #expect(await reader.value == nil)
        #expect(await iterator.next() == "cancelled")
        #expect(await transport.requests.count == held + 1)
    }

    @Test(arguments: [false, true]) func htmlPrefixStopsAtCapAndParsesHead(_ chunked: Bool) throws {
        let html = "<head><link rel=icon href=/mark.png></head>" + String(repeating: "x", count: 1024)
        let framing = chunked ? "Transfer-Encoding: chunked" : "Content-Length: 1000000"
        let body = chunked ? "100000\r\n" + html : html
        var reader = RemoteFetchReplyReader(maximumBody: 128, allowsTruncation: true)
        #expect(try reader.append(Data("HTTP/1.1 200 OK\r\n\(framing)\r\n\r\n\(body)".utf8)))
        let response = try reader.finish()
        #expect(response.body.count == 128)
        let url = try #require(URL(string: "https://source.example/"))
        #expect(AgentPaneSourceIconHTML().candidates(in: response.body, pageURL: url).map(\.path) == ["/mark.png"])
    }

    @Test func unframedHTMLPrefixStopsAtCap() throws {
        var reader = RemoteFetchReplyReader(maximumBody: 3, allowsTruncation: true)
        #expect(try reader.append(Data("HTTP/1.1 200 OK\r\n\r\nabcdef".utf8)))
        #expect(try reader.finish().body == Data("abc".utf8))
    }

    @Test func shortHTMLResponseStillNeedsValidFraming() throws {
        var reader = RemoteFetchReplyReader(maximumBody: 128, allowsTruncation: true)
        #expect(try reader.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort".utf8)) == false)
        #expect(throws: RemoteFetchReplyReader.Refusal.self) { try reader.finish() }
    }

    @Test func encodedHTMLIsRefusedWhenIdentityWasRequested() throws {
        var reader = RemoteFetchReplyReader(maximumBody: 128, allowsTruncation: true)
        #expect(throws: RemoteFetchReplyReader.Refusal.self) {
            try reader.append(Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nencoded".utf8))
        }
    }

    @Test func imageFetchStillRefusesOversizedBody() throws {
        var reader = RemoteFetchReplyReader(maximumBody: 2)
        #expect(throws: RemoteFetchReplyReader.Refusal.self) {
            try reader.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc".utf8))
        }
    }
}
