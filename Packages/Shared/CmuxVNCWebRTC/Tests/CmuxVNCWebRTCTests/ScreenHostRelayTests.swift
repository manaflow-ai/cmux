@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// The relay between the app and the Screen Sharing helper's WebRTC host child
/// (ScreenHostRelay.swift): the lines, and the child's end, `ScreenRelayRunner`.
struct ScreenHostRelayTests {
    static let offer = ScreenSignal.offer("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 AB:CD\r\n")
    static let candidate = ScreenSignal.candidate(ScreenICECandidate(candidate: "candidate:1 1 udp 1 10.0.0.2 5000 typ host",
                                                                     sdpMid: "0", sdpMLineIndex: 0))
    static let setup = ScreenRelaySetup(name: "Studio", viewOnly: true, endsSessionOnClose: true,
                                        iceServers: [ICEServerConfig(urls: ["turn:turn.example:3478"], username: "u", credential: "c")],
                                        excludeWindows: [42, 7])

    @Test func everySignalRoundTripsThroughALine() throws {
        let signals: [ScreenSignal] = [.hello(peerPresent: true), .hello(peerPresent: false), .peerJoined, .peerLeft,
                                       Self.offer, .answer("v=0\r\n"), Self.candidate,
                                       .candidate(ScreenICECandidate(candidate: "c", sdpMid: nil, sdpMLineIndex: nil)),
                                       .bye, .path(relay: true), .path(relay: false)]
        for signal in signals {
            var buffer = ScreenRelayLineBuffer()
            let lines = buffer.push(ScreenRelayLine(signal: signal).encoded)
            #expect(lines.count == 1)
            #expect(lines.first?.signal?.signal == signal)
        }
        #expect(ScreenRelaySignal(type: "newer-kind").signal == nil, "a newer peer's signal is skipped, not misread")
        #expect(ScreenRelaySignal(type: "offer").signal == nil)
    }

    @Test func theSetupKeepsItsSnakeCaseNamesAndValues() throws {
        let data = ScreenRelayLine(setup: Self.setup).encoded
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("\"exclude_windows\":[42,7]"))
        #expect(text.contains("\"view_only\":true"))
        #expect(text.contains("\"ends_session_on_close\":true"))
        var buffer = ScreenRelayLineBuffer()
        #expect(buffer.push(data).first?.setup == Self.setup)
    }

    @Test func linesSplitAcrossChunksArriveWholeAndGarbageIsDropped() {
        var buffer = ScreenRelayLineBuffer()
        let line = ScreenRelayLine(excludeWindows: [1, 2, 3]).encoded
        let middle = line.count / 2
        #expect(buffer.push(Data("not json\n".utf8)).isEmpty)
        #expect(buffer.push(line.prefix(middle)).isEmpty)
        let lines = buffer.push(line.suffix(from: middle) + ScreenRelayLine(stop: true).encoded)
        #expect(lines == [ScreenRelayLine(excludeWindows: [1, 2, 3]), ScreenRelayLine(stop: true)])
        // A line that never ends is not kept without bound.
        #expect(buffer.push(Data(repeating: UInt8(ascii: "x"), count: ScreenRelayLineBuffer.limit + 1)).isEmpty)
        #expect(buffer.push(ScreenRelayLine(stop: true).encoded) == [ScreenRelayLine(stop: true)])
    }

    @Test func theRunnerServesTheSessionAndRelaysBothWays() async throws {
        let (input, feed) = AsyncStream.makeStream(of: Data.self)
        let output = Output()
        let host = FakeHost()
        let made = Made()
        let runner = ScreenRelayRunner(input: input, write: { output.append($0) }, log: { _ in }) { setup, exclusions in
            made.record(setup, exclusions)
            return host
        }
        let exit = Task { await runner.run() }
        feed.yield(ScreenRelayLine(setup: Self.setup).encoded)
        feed.yield(ScreenRelayLine(signal: Self.offer).encoded + ScreenRelayLine(signal: Self.candidate).encoded)
        try await waitUntil { host.received.count == 2 }
        #expect(host.received == [Self.offer, Self.candidate])
        #expect(made.setup == Self.setup)
        #expect(made.exclusions?.windowIDs == [42, 7], "the capture's first list came with the setup")
        #expect(host.iceServers == Self.setup.iceServers)

        // A new exclusion list reaches the capture at once; the same list again does nothing.
        let changes = Counter()
        made.exclusions?.onChange { changes.bump() }
        feed.yield(ScreenRelayLine(excludeWindows: [9]).encoded + ScreenRelayLine(excludeWindows: [9]).encoded)
        try await waitUntil { made.exclusions?.windowIDs == [9] }
        #expect(changes.count == 1)

        // The host's answer, its events and its close go back to the app as lines.
        try await host.signaling?.send(.answer("v=0\r\nanswer"))
        host.onEvent?(.viewerConnected)
        host.signaling?.close()
        host.signaling?.close()
        try await waitUntil { output.lines.count == 3 }
        #expect(output.lines == [ScreenRelayLine(signal: .answer("v=0\r\nanswer")),
                                 ScreenRelayLine(event: ScreenRelayLine.connected),
                                 ScreenRelayLine(close: true)], "one close line, however often the host closes")

        feed.yield(ScreenRelayLine(stop: true).encoded)
        #expect(await exit.value == 0)
        #expect(host.disconnected)
    }

    @Test func theRunnerEndsOnceServedWithNoViewerConnected() async throws {
        let (input, feed) = AsyncStream.makeStream(of: Data.self)
        let output = Output()
        let host = FakeHost()
        let runner = ScreenRelayRunner(input: input, write: { output.append($0) }, log: { _ in }) { _, _ in host }
        let exit = Task { await runner.run() }
        feed.yield(ScreenRelayLine(setup: Self.setup).encoded)
        feed.yield(ScreenRelayLine(signal: Self.offer).encoded + ScreenRelayLine(signalsEnd: true).encoded)
        #expect(await exit.value == 0)
        #expect(output.lines.last == ScreenRelayLine(served: true))
        #expect(host.received == [Self.offer])
    }

    @Test func aConnectedSessionOutlivesItsSignalingUntilTheViewerLeaves() async throws {
        let (input, feed) = AsyncStream.makeStream(of: Data.self)
        let output = Output()
        let host = FakeHost()
        let runner = ScreenRelayRunner(input: input, write: { output.append($0) }, log: { _ in }) { _, _ in host }
        let exit = Task { await runner.run() }
        feed.yield(ScreenRelayLine(setup: Self.setup).encoded)
        try await waitUntil { host.signaling != nil }
        host.onEvent?(.viewerConnected)
        feed.yield(ScreenRelayLine(signalsEnd: true).encoded)
        try await waitUntil { output.lines.contains(ScreenRelayLine(served: true)) }
        host.onEvent?(.sourceFailed("no display"))
        host.onEvent?(.viewerEnded)
        #expect(await exit.value == 0)
        #expect(output.lines.suffix(2) == [ScreenRelayLine(event: ScreenRelayLine.failed, message: "no display"),
                                           ScreenRelayLine(event: ScreenRelayLine.ended)])
    }

    @Test func aLineBeforeTheSetupStopsTheChildAndTheInputsEndStopsTheSession() async throws {
        let (early, feedEarly) = AsyncStream.makeStream(of: Data.self)
        let neverMade = FakeHost()
        let refused = ScreenRelayRunner(input: early, write: { _ in }, log: { _ in }) { _, _ in neverMade }
        feedEarly.yield(ScreenRelayLine(signal: Self.offer).encoded)
        #expect(await refused.run() == 2)
        #expect(neverMade.signaling == nil)

        let (input, feed) = AsyncStream.makeStream(of: Data.self)
        let host = FakeHost()
        let runner = ScreenRelayRunner(input: input, write: { _ in }, log: { _ in }) { _, _ in host }
        feed.yield(ScreenRelayLine(setup: Self.setup).encoded)
        feed.finish()
        #expect(await runner.run() == 0)
        #expect(host.disconnected, "the app ended or closed the child's stdin: the session ends with it")
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

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ScreenRelayLineBuffer()
    private var items: [ScreenRelayLine] = []
    func append(_ data: Data) { lock.withLock { items += buffer.push(data) } }
    var lines: [ScreenRelayLine] { lock.withLock { items } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var made: (ScreenRelaySetup, ScreenRelayExclusions)?
    func record(_ setup: ScreenRelaySetup, _ exclusions: ScreenRelayExclusions) { lock.withLock { made = (setup, exclusions) } }
    var setup: ScreenRelaySetup? { lock.withLock { made?.0 } }
    var exclusions: ScreenRelayExclusions? { lock.withLock { made?.1 } }
}

/// Records what the runner hands its host: the signaling, its signals and ICE servers, the disconnect.
private final class FakeHost: ScreenRelayServedHost, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (ScreenStreamHost.Event) -> Void)?
    private var served: (any ScreenSignaling)?
    private var signals: [ScreenSignal] = []
    private var servers: [ICEServerConfig] = []
    private var stopped = false

    var onEvent: (@Sendable (ScreenStreamHost.Event) -> Void)? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }

    func serve(_ signaling: any ScreenSignaling) async throws {
        let servers = try await signaling.iceServers()
        lock.withLock {
            served = signaling
            self.servers = servers
        }
        for try await signal in signaling.messages() { lock.withLock { signals.append(signal) } }
    }

    func disconnectViewer() { lock.withLock { stopped = true } }

    var signaling: (any ScreenSignaling)? { lock.withLock { served } }
    var received: [ScreenSignal] { lock.withLock { signals } }
    var iceServers: [ICEServerConfig] { lock.withLock { servers } }
    var disconnected: Bool { lock.withLock { stopped } }
}
