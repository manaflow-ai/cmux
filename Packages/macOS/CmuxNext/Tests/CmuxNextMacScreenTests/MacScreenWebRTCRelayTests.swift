import CmuxNextCompat
@testable import CmuxNextMacScreen
import CmuxScreenKit
import CoreGraphics
import Foundation
import Testing

/// An iPhone (WebRTC) viewer is served by the Screen Sharing helper, never in the app
/// (``MacScreenWebRTCRelay``): the app relays the session's signaling and the windows the capture
/// leaves out to the helper's `__webrtc-host` in JSON lines. A stand-in on three pipes plays the
/// helper here: it reads what the app writes to its stdin and writes the helper's lines.
@Suite struct MacScreenWebRTCRelayTests {
    static let offer = ScreenSignal.offer("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 AB:CD\r\n")
    static let servers = [ICEServerConfig(urls: ["turn:turn.example:3478"], username: "u", credential: "c")]

    @Test func theSessionsSignalsEventsAndExclusionsCrossTheHelpersPipes() async throws {
        let child = StandIn()
        let windows = Windows([5])
        let events = Events()
        let relay = MacScreenWebRTCRelay(name: "Studio", viewOnly: true, launch: { child.pipes },
                                         excludedWindows: { windows.ids }, recheck: .milliseconds(10))
        relay.onEvent = { events.append($0) }
        let signaling = Signaling(servers: Self.servers)
        let serve = Task { try await relay.serve(signaling) }

        // SECURITY: the first exclusion list comes with the setup, before any offer.
        let setup = try #require(await child.line { $0.setup != nil }?.setup)
        #expect(setup == ScreenRelaySetup(name: "Studio", viewOnly: true, endsSessionOnClose: true,
                                          iceServers: Self.servers, excludeWindows: [5]))

        signaling.deliver(Self.offer)
        #expect(await child.line { $0.signal != nil }?.signal?.signal == Self.offer)

        // The helper's answer, its events and its close reach the session.
        child.write(ScreenRelayLine(signal: .answer("v=0\r\nanswer")))
        child.write(ScreenRelayLine(event: ScreenRelayLine.connected))
        child.write(ScreenRelayLine(close: true))
        try await waitUntil { signaling.closed && events.all == [.viewerConnected] }
        #expect(signaling.sent == [.answer("v=0\r\nanswer")])

        // A window that asks not to be shared shows: the whole new list goes to the helper.
        windows.set([5, 6])
        #expect(await child.line { $0.excludeWindows == [5, 6] } != nil)

        // The session's signaling ended: the helper hears it, and serve returns once it served.
        signaling.finish()
        #expect(await child.line { $0.signalsEnd == true } != nil)
        child.write(ScreenRelayLine(served: true))
        try await serve.value

        // Stop: a `stop` line, then the end of the helper's stdin.
        relay.disconnectViewer()
        #expect(await child.line { $0.stop == true } != nil)
        try await waitUntil { child.inputEnded }
        #expect(signaling.sent == [.answer("v=0\r\nanswer")], "no bye once the signaling was served")
    }

    @Test func aStopWhileServingSaysByeAndTheHelpersEndIsNotAFailure() async throws {
        let child = StandIn()
        let events = Events()
        let relay = MacScreenWebRTCRelay(name: "Studio", viewOnly: false, launch: { child.pipes }, excludedWindows: { [] })
        relay.onEvent = { events.append($0) }
        let signaling = Signaling(servers: [])
        let serve = Task { try await relay.serve(signaling) }
        #expect(await child.line { $0.setup != nil } != nil)

        relay.disconnectViewer()
        #expect(await child.line { $0.stop == true } != nil)
        try await waitUntil { signaling.sent == [.bye] && signaling.closed }
        child.end()
        signaling.finish()
        try await serve.value
        #expect(events.all.isEmpty, "the helper ended because this side stopped it")
    }

    @Test func aHelperThatEndsBeforeTheViewerConnectedFailsTheSessionWithItsReason() async throws {
        let child = StandIn()
        let events = Events()
        let relay = MacScreenWebRTCRelay(name: "Studio", viewOnly: false, launch: { child.pipes }, excludedWindows: { [] })
        relay.onEvent = { events.append($0) }
        let signaling = Signaling(servers: [])
        let serve = Task { try await relay.serve(signaling) }
        #expect(await child.line { $0.setup != nil } != nil)
        child.complain("this Screen Sharing helper carries no WebRTC host")
        try await Task.sleep(for: .milliseconds(100))
        child.end()
        try await waitUntil { !events.all.isEmpty }
        #expect(events.all == [.sourceFailed("this Screen Sharing helper carries no WebRTC host")])
        signaling.finish()
        try await serve.value
    }

    @Test func aHelperThatWillNotStartFailsTheSession() async throws {
        let events = Events()
        let relay = MacScreenWebRTCRelay(name: "Studio", viewOnly: false,
                                         launch: { throw MacScreenWebRTCRelay.NoHelper() }, excludedWindows: { [] })
        relay.onEvent = { events.append($0) }
        try await relay.serve(Signaling(servers: []))
        #expect(events.all == [.sourceFailed("this build has no Screen Sharing helper to serve the viewer")])
    }

    @Test func aViewersEndAndAHostFailureArriveAsTheirEvents() async throws {
        let child = StandIn()
        let events = Events()
        let relay = MacScreenWebRTCRelay(name: "Studio", viewOnly: false, launch: { child.pipes }, excludedWindows: { [] })
        relay.onEvent = { events.append($0) }
        let signaling = Signaling(servers: [])
        let serve = Task { try await relay.serve(signaling) }
        #expect(await child.line { $0.setup != nil } != nil)
        child.write(ScreenRelayLine(event: ScreenRelayLine.connected))
        child.write(ScreenRelayLine(event: ScreenRelayLine.failed, message: "no display"))
        child.write(ScreenRelayLine(event: ScreenRelayLine.ended))
        child.write(ScreenRelayLine(served: true, error: "fingerprint"))
        child.end()
        signaling.finish()
        await #expect(throws: MacScreenWebRTCRelay.Served.self) { try await serve.value }
        try await waitUntil { events.all.count == 3 }
        #expect(events.all == [.viewerConnected, .sourceFailed("no display"), .viewerEnded("the WebRTC viewer left")],
                "the helper's own end after its events says nothing more")
    }
}

// MARK: - Test doubles

/// Waits up to 5 s for `condition`.
private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// The helper's side of its three pipes.
private nonisolated final class StandIn: Sendable {
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private struct Read {
        var buffer = ScreenRelayLineBuffer()
        var lines: [ScreenRelayLine] = []
        var ended = false
    }
    private let read = Mutex(Read())

    init() {
        let (chunks, _) = stdin.fileHandleForReading.readyChunks()
        let read = read
        Task {
            for await data in chunks { read.withLock { $0.lines += $0.buffer.push(data) } }
            read.withLock { $0.ended = true }
        }
    }

    var pipes: MacScreenWebRTCRelay.Child {
        MacScreenWebRTCRelay.Child(input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading,
                                   errors: stderr.fileHandleForReading, pipes: [stdin, stdout, stderr])
    }

    var inputEnded: Bool { read.withLock { $0.ended } }

    /// The first line the app wrote that `matches`, waiting up to 5 s.
    func line(_ matches: @escaping @Sendable (ScreenRelayLine) -> Bool) async -> ScreenRelayLine? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let found = read.withLock({ $0.lines.first(where: matches) }) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func write(_ line: ScreenRelayLine) { try? stdout.fileHandleForWriting.write(contentsOf: line.encoded) }
    func complain(_ text: String) { try? stderr.fileHandleForWriting.write(contentsOf: Data(text.utf8)) }

    /// The helper exits: its stdout and stderr close.
    func end() {
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }
}

private nonisolated final class Windows: Sendable {
    private let current: Mutex<Set<CGWindowID>>
    init(_ ids: Set<CGWindowID>) { current = Mutex(ids) }
    var ids: Set<CGWindowID> { current.withLock { $0 } }
    func set(_ ids: Set<CGWindowID>) { current.withLock { $0 = ids } }
}

private nonisolated final class Events: Sendable {
    private let items = Mutex<[MacScreenRdHost.Event]>([])
    func append(_ event: MacScreenRdHost.Event) { items.withLock { $0.append(event) } }
    var all: [MacScreenRdHost.Event] { items.withLock { $0 } }
}

/// The session's signaling: signals the test delivers, what the relay sent and whether it closed.
private nonisolated final class Signaling: ScreenSignaling {
    private struct Recorded {
        var sent: [ScreenSignal] = []
        var closed = false
    }
    private let servers: [ICEServerConfig]
    private let recorded = Mutex(Recorded())
    private let stream: AsyncThrowingStream<ScreenSignal, any Error>
    private let continuation: AsyncThrowingStream<ScreenSignal, any Error>.Continuation

    init(servers: [ICEServerConfig]) {
        self.servers = servers
        (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self)
    }

    func deliver(_ signal: ScreenSignal) { continuation.yield(signal) }
    func finish() { continuation.finish() }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }
    func send(_ signal: ScreenSignal) async throws { recorded.withLock { $0.sent.append(signal) } }
    func iceServers() async throws -> [ICEServerConfig] { servers }
    func close() { recorded.withLock { $0.closed = true } }
    var endsSessionOnClose: Bool { true }

    var sent: [ScreenSignal] { recorded.withLock { $0.sent } }
    var closed: Bool { recorded.withLock { $0.closed } }
}
