import CmuxNextCompat
import CmuxNextRemoteView
import CmuxScreenKit
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// Exercises signaling/Rust-output ordering without a child process, capture grant or WebRTC engine.
@Suite(.timeLimit(.minutes(1))) struct MacScreenHostFallbackTests {
    nonisolated final class Worker: MacScreenRdWorker {
        let lines: AsyncStream<MacScreenRdMessage>
        private let output: AsyncStream<MacScreenRdMessage>.Continuation
        let commands: AsyncStream<Data>
        private let command: AsyncStream<Data>.Continuation
        // The protocol has synchronous process callbacks; only these test counters use this lock.
        private let state = Mutex((started: false, stops: 0))
        var started: Bool { state.load().started }
        var stops: Int { state.load().stops }
        var stderrTail: String { "" }

        init() {
            (lines, output) = AsyncStream.makeStream(of: MacScreenRdMessage.self)
            (commands, command) = AsyncStream.makeStream(of: Data.self)
        }
        func start(_ role: MacScreenRdProcess.Role) { state.withLock { $0.started = true } }
        func send<Value: Encodable>(_ value: Value) {
            if let data = try? JSONEncoder().encode(value) { command.yield(data) }
        }
        func stop() {
            state.withLock { $0.stops += 1 }
            output.finish()
            command.finish()
        }
        func emit(_ json: String) throws {
            let reader = try #require(RemoteRdLineReader())
            let line = try #require(reader.push(Data((json + "\n").utf8)).first)
            output.yield(line)
        }
    }

    nonisolated final class Signaling: ScreenSignaling {
        private let stream: AsyncThrowingStream<ScreenSignal, any Error>
        let input: AsyncThrowingStream<ScreenSignal, any Error>.Continuation
        init() { (stream, input) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self) }
        func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }
        func send(_ signal: ScreenSignal) async throws {}
        func iceServers() async throws -> [ICEServerConfig] { [] }
        func close() { input.finish() }
        var endsSessionOnClose: Bool { true }
    }

    /// Models resource preparation that completes even after its caller was cancelled.
    /// The receipt establishes the ordering without polling or sleeps.
    nonisolated final class Preparation: Sendable {
        let entered: AsyncStream<Bool>
        private let entry: AsyncStream<Bool>.Continuation
        private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

        init() { (entered, entry) = AsyncStream.makeStream(of: Bool.self) }
        func wait() async {
            await withCheckedContinuation { next in
                continuation.store(next)
                entry.yield(true)
            }
        }
        func finish() {
            let next = continuation.withLock { value in
                defer { value = nil }
                return value
            }
            next?.resume()
            entry.finish()
        }
    }

    nonisolated final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.load() }
    }

    private let session = MacScreenRdHost.Session(id: "approved-session", name: "Host", viewerID: "viewer",
                                                 viewOnly: false, servers: MacScreenRdServers([]))
    private let webOffer = ScreenSignal.offer("v=0\r\na=fingerprint:sha-256 AB:CD\r\n")

    @Test(arguments: [false, true])
    func permittedFallbackForwardsExactlyOneOfferInEitherArrivalOrder(decisionFirst: Bool) async throws {
        let worker = Worker(), signaling = Signaling()
        let (received, receipt) = AsyncStream.makeStream(of: ScreenSignal.self)
        let host = MacScreenRdHost(session: session, process: worker) { forwarded in
            defer { receipt.finish() }
            for try await signal in forwarded.messages() { receipt.yield(signal) }
        }
        let serve = Task { try await host.serve(signaling) }
        defer { serve.cancel(); host.disconnectViewer(); signaling.close() }
        signaling.input.yield(.offer(MacScreenRdDocument(key: String(repeating: "a", count: 64), peerCarrier: "rd_wg/1").text))
        var commands = worker.commands.makeAsyncIterator()
        let setup = try #require(await commands.next())
        let json = try #require(JSONSerialization.jsonObject(with: setup) as? [String: Any])
        #expect(json["peer_carrier"] as? String == "rd_wg/1")
        let decision = #"{"fallback":{"carrier":"rd_wg","reason":"timeout","retry":"web_rtc"}}"#
        if decisionFirst { try worker.emit(decision) }
        signaling.input.yield(webOffer)
        if !decisionFirst { try worker.emit(decision) }
        signaling.input.yield(.bye)
        signaling.input.finish()
        try await serve.value
        var actual: [ScreenSignal] = []
        for await signal in received { actual.append(signal) }
        #expect(actual == [webOffer, .bye])
        #expect(worker.stops == 1)
    }

    @Test(arguments: [#"{"connected":true}"#, #"{"ended":"revoked"}"#])
    func connectedOrRevokedSessionCannotBecomeWebRTC(_ decision: String) async throws {
        let worker = Worker(), signaling = Signaling()
        let (starts, started) = AsyncStream.makeStream(of: Bool.self)
        let host = MacScreenRdHost(session: session, process: worker) { _ in started.yield(true) }
        let serve = Task { try await host.serve(signaling) }
        defer { serve.cancel(); host.disconnectViewer(); signaling.close() }
        signaling.input.yield(.offer(MacScreenRdDocument(key: String(repeating: "a", count: 64)).text))
        var commands = worker.commands.makeAsyncIterator()
        _ = try #require(await commands.next())
        try worker.emit(decision)
        signaling.input.yield(webOffer)
        signaling.input.yield(.bye)
        signaling.input.finish()
        try await serve.value
        started.finish()
        var count = 0
        for await _ in starts { count += 1 }
        #expect(count == 0)
    }

    @Test func eventHandlerCanRevokeHostSynchronously() async throws {
        let worker = Worker(), signaling = Signaling()
        let (events, event) = AsyncStream.makeStream(of: MacScreenRdHost.Event.self)
        let host = MacScreenRdHost(session: session, process: worker)
        host.onEvent = { received in
            host.disconnectViewer()
            event.yield(received)
            event.finish()
        }
        let serve = Task { try await host.serve(signaling) }
        defer { serve.cancel(); host.disconnectViewer(); signaling.close(); event.finish() }
        signaling.input.yield(.offer(MacScreenRdDocument(key: String(repeating: "a", count: 64)).text))
        var commands = worker.commands.makeAsyncIterator()
        _ = try #require(await commands.next())
        try worker.emit(#"{"connected":true}"#)
        var received = events.makeAsyncIterator()
        #expect(await received.next() == .viewerConnected)
        try await serve.value
        #expect(worker.stops == 1)
    }

    @Test func stopBeforeFallbackOfferCannotStartAnotherHost() async throws {
        let worker = Worker(), signaling = Signaling()
        let starts = Counter()
        let host = MacScreenRdHost(session: session, process: worker) { _ in starts.increment() }
        let serve = Task { try await host.serve(signaling) }
        defer { serve.cancel(); host.disconnectViewer(); signaling.close() }
        signaling.input.yield(.offer(MacScreenRdDocument(key: String(repeating: "a", count: 64), peerCarrier: "rd_wg/1").text))
        var commands = worker.commands.makeAsyncIterator()
        _ = try #require(await commands.next())
        try worker.emit(#"{"fallback":{"carrier":"rd_wg","reason":"timeout","retry":"web_rtc"}}"#)
        host.disconnectViewer()
        signaling.input.yield(webOffer)
        signaling.input.finish()
        try await serve.value
        #expect(starts.count == 0)
        // A new call on the same retired owner cannot redeem or read another ticket either.
        let later = Signaling()
        later.input.yield(webOffer)
        later.input.finish()
        try await host.serve(later)
        #expect(starts.count == 0)
    }

    @Test func stopDuringFallbackPreparationPreventsLateInstallation() async throws {
        let worker = Worker(), signaling = Signaling(), preparation = Preparation()
        let starts = Counter()
        let host = MacScreenRdHost(session: session, process: worker,
                                  prepareWebRTC: { await preparation.wait() }) { _ in starts.increment() }
        let serve = Task { try await host.serve(signaling) }
        defer { preparation.finish(); serve.cancel(); host.disconnectViewer(); signaling.close() }
        signaling.input.yield(.offer(MacScreenRdDocument(key: String(repeating: "a", count: 64), peerCarrier: "rd_wg/1").text))
        var commands = worker.commands.makeAsyncIterator()
        _ = try #require(await commands.next())
        try worker.emit(#"{"fallback":{"carrier":"rd_wg","reason":"timeout","retry":"web_rtc"}}"#)
        signaling.input.yield(webOffer)
        var entered = preparation.entered.makeAsyncIterator()
        #expect(await entered.next() == true)
        host.disconnectViewer()
        preparation.finish()
        try await serve.value
        #expect(starts.count == 0)
    }
}
