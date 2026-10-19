import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneSourceIconAdmissionTests {
    private actor Resolver: RemoteAddressResolving {
        func resolve(_ host: String) async throws -> [RemoteAddress] { [.v4([93, 184, 216, 34])] }
    }

    private actor HeldTransport: RemoteFetchTransport {
        let starts: AsyncStream<RemoteFetchRequest>.Continuation
        var requests: [RemoteFetchRequest] = []
        var waiting: [UUID: CheckedContinuation<RemoteFetchResponse, any Error>] = [:]
        var peak = 0

        init(starts: AsyncStream<RemoteFetchRequest>.Continuation) { self.starts = starts }

        func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    waiting[id] = continuation
                    requests.append(request)
                    peak = max(peak, waiting.count)
                    starts.yield(request)
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func cancel(_ id: UUID) {
            waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }

        func finish() {
            let pending = waiting.values
            waiting.removeAll()
            for continuation in pending {
                continuation.resume(returning: RemoteFetchResponse(status: 200, headers: [:], body: Data([1])))
            }
        }
    }

    private func loader(_ transport: HeldTransport, concurrent: Int = 4, queued: Int = 128) -> AgentPaneSourceIcons {
        AgentPaneSourceIcons(maximumConcurrent: concurrent, maximumQueued: queued,
                             fetch: GuardedRemoteFetch(maximumBytes: 1 << 20, timeout: .seconds(10),
                                                       accept: GuardedRemoteFetch.imageAccept,
                                                       resolver: Resolver(), transport: transport), decode: { $0 })
    }

    @Test func aThousandOriginsStayWithinTheNativeAdmissionBound() async throws {
        let (starts, continuation) = AsyncStream<RemoteFetchRequest>.makeStream()
        let transport = HeldTransport(starts: continuation)
        let icons = loader(transport)
        var readers: [(url: URL, id: UUID, task: Task<Data?, Never>)] = []
        for index in 0..<1000 {
            let url = try #require(URL(string: "https://site\(index).example/favicon.ico"))
            let id = UUID()
            readers.append((url, id, await icons.request(at: url, id: id)))
        }
        var iterator = starts.makeAsyncIterator()
        for _ in 0..<4 { _ = await iterator.next() }
        // Overflow is refused without growing the queue beyond 128 waiting origins.
        for reader in readers.dropFirst(132) { #expect(await reader.task.value == nil) }
        #expect(await transport.requests.count == 4)
        for reader in readers.dropFirst(4) { await icons.cancel(at: reader.url, id: reader.id) }
        for reader in readers.prefix(4) { await icons.cancel(at: reader.url, id: reader.id) }
        for reader in readers { _ = await reader.task.value }
        #expect(await transport.peak <= 4)
        #expect(await transport.requests.count <= 4)
    }

    @Test func duplicateOriginsShareWorkAndOneCancelledWaiterDoesNotCancelTheOther() async throws {
        let (starts, continuation) = AsyncStream<RemoteFetchRequest>.makeStream()
        let transport = HeldTransport(starts: continuation)
        let icons = loader(transport)
        let url = try #require(URL(string: "https://same.example/favicon.ico"))
        let first = Task { await icons.data(at: url) }
        var iterator = starts.makeAsyncIterator()
        _ = await iterator.next()
        // Register the second waiter synchronously at the actor before cancelling the first.
        let secondID = UUID()
        let second = await icons.request(at: url, id: secondID)
        first.cancel()
        #expect(await first.value == nil)
        await transport.finish()
        #expect(await second.value == Data([1]))
        #expect(await transport.requests.count == 1)
    }

    @Test func cancellingQueuedAndActiveWorkNeverStartsTheAbandonedOrigin() async throws {
        let (starts, continuation) = AsyncStream<RemoteFetchRequest>.makeStream()
        let transport = HeldTransport(starts: continuation)
        let icons = loader(transport, concurrent: 1, queued: 1)
        let activeURL = try #require(URL(string: "https://active.example/favicon.ico"))
        let queuedURL = try #require(URL(string: "https://queued.example/favicon.ico"))
        let active = Task { await icons.data(at: activeURL) }
        var iterator = starts.makeAsyncIterator()
        _ = await iterator.next()
        let id = UUID()
        let queued = await icons.request(at: queuedURL, id: id)
        await icons.cancel(at: queuedURL, id: id)
        #expect(await queued.value == nil)
        active.cancel()
        #expect(await active.value == nil)
        #expect(await transport.requests.map(\.host) == ["active.example"])
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor @Test func pageCancellationAndLabDisableReleaseThePaneReaders() async throws {
        for disableLab in [false, true] {
            let (starts, continuation) = AsyncStream<RemoteFetchRequest>.makeStream()
            let transport = HeldTransport(starts: continuation)
            let icons = loader(transport)
            let model = AgentPaneModel(host: NoHost())
            model.replyLinks.sourceIconsBaseline = true
            model.replyLinks.favicon = { url in await icons.data(at: url) }
            let url = try #require(URL(string: "https://source.example/page"))
            let response = Task {
                let reply = await model.respond(to: .favicon(url))
                return (reply["value"] as? [String: Any])?["icon"] != nil
            }
            var iterator = starts.makeAsyncIterator()
            _ = await iterator.next()
            if disableLab {
                model.replyLinks.applySourceIconLayout(AgentPaneCustomization(layoutJSON: #"{"labs":{"sourceIcons":false}}"#))
            } else {
                _ = await model.respond(to: .cancelFavicon(url))
            }
            #expect(await response.value == false)
            #expect(await transport.requests.count == 1)
        }
    }
}
