import CmuxNextCompat
import CmuxScreenKit
import CoreGraphics
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// The iPhone viewer's WebRTC host in the Screen Sharing helper's child: the app relays the
/// session's signaling in JSON lines (``MacScreenStreamLine``) and the child serves it, so the
/// capture and input use the helper's grants (plans/cmux-next/screen-sharing-helper.md).
@Suite struct MacScreenStreamProcessTests {
    /// A session's signaling that records what the host sent; its incoming signals are `incoming`.
    final class RecordingSignaling: ScreenSignaling {
        let sent = Mutex<[ScreenSignal]>([])
        let closes = Mutex(0)
        let stream: AsyncThrowingStream<ScreenSignal, any Error>
        let incoming: AsyncThrowingStream<ScreenSignal, any Error>.Continuation
        var endsSessionOnClose: Bool { true }

        init() {
            (stream, incoming) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self)
        }

        func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }
        func send(_ signal: ScreenSignal) async throws { sent.withLock { $0.append(signal) } }
        func iceServers() async throws -> [ICEServerConfig] { [ICEServerConfig(urls: ["stun:stun.example:3478"])] }
        func close() { closes.withLock { $0 += 1 } }
    }

    @Test func everySignalRoundTripsTheWire() throws {
        let signals: [ScreenSignal] = [
            .hello(peerPresent: true), .peerJoined, .peerLeft, .offer("v=0 offer"), .answer("v=0 answer"),
            .candidate(ScreenICECandidate(candidate: "candidate:1 1 udp 1 10.0.0.2 5000 typ host", sdpMid: "0", sdpMLineIndex: 0)),
            .bye, .path(relay: true),
        ]
        for signal in signals {
            let data = try #require(MacScreenStreamLine(signal: .init(signal)).encoded)
            var splitter = MacScreenStreamLineSplitter()
            let lines = splitter.push(data)
            #expect(lines.count == 1)
            #expect(lines.first?.signal?.signal == signal)
        }
    }

    @Test func theSplitterJoinsPartialLinesAndSkipsBadOnes() throws {
        let setup = try #require(MacScreenStreamLine(setup: .init(name: "Mac", viewOnly: true, endsSessionOnClose: false),
                                                     excludeWindows: [7, 9]).encoded)
        var splitter = MacScreenStreamLineSplitter()
        #expect(splitter.push(setup.prefix(10)).isEmpty)
        let lines = splitter.push(setup.dropFirst(10) + Data("not json\n{\"stop\":true}\n".utf8))
        #expect(lines.count == 2)
        #expect(lines.first?.setup == .init(name: "Mac", viewOnly: true, endsSessionOnClose: false))
        #expect(lines.first?.excludeWindows == [7, 9])
        #expect(lines.last?.stop == true)
        let text = String(decoding: setup, as: UTF8.self)
        #expect(text.contains("\"exclude_windows\":[7,9]"))
        #expect(text.contains("\"view_only\":true"))
    }

    /// The helper starts the app's executable in its stream host mode; anything else is the app.
    @Test func theChildModeIsOnlyItsOwnArgument() {
        let arguments = MacScreenStreamProcess.helperArguments(appExecutable: URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux NIGHTLY"))
        #expect(arguments == ["__webrtc-host", "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux NIGHTLY", "--screen-stream-host"])
        #expect(MacScreenStreamChild(arguments: Array(arguments.dropFirst())) != nil)
        #expect(MacScreenStreamChild(arguments: ["/x/cmux"]) == nil)
        #expect(MacScreenStreamChild(arguments: ["/x/cmux", "--screen-stream-host", "extra"]) == nil)
        #expect(MacScreenStreamChild(arguments: ["/x/cmux", "-NSDocumentRevisionsDebugMode"]) == nil)
    }

    /// A shell stands in for the helper's child: it checks the setup carries the excluded windows,
    /// answers, asks for ICE servers and checks the app's answer, then reports, closes and ends.
    static let child = """
    read setup
    case "$setup" in *'"exclude_windows":[7,9]'*'"name":"Mac"'*|*'"name":"Mac"'*'"exclude_windows":[7,9]'*) ;; *) echo "bad setup $setup" >&2; exit 3;; esac
    printf '%s\\n' '{"signal":{"type":"answer","sdp":"v=0 child"}}' '{"ice_request":1}'
    read ice
    case "$ice" in *'"id":1'*'stun:stun.example:3478'*) ;; *) echo "bad ice $ice" >&2; exit 4;; esac
    printf '%s\\n' '{"event":"viewer_connected"}' '{"close":true}' '{"done":{}}'
    cat >/dev/null
    """

    @Test func theAppRelaysTheSessionToTheChild() async throws {
        let process = MacScreenStreamProcess()
        try process.start { stdin, stdout, stderr in
            try MacScreenHelper.spawn(URL(fileURLWithPath: "/bin/sh"), ["-c", Self.child], stdin: stdin, stdout: stdout, stderr: stderr)
        }
        let signaling = RecordingSignaling()
        let events = Mutex<[MacScreenStreamLine.Event]>([])
        try await process.serve(signaling, name: "Mac", viewOnly: false, excluded: [9, 7]) { event, _ in
            events.withLock { $0.append(event) }
        }
        process.stop()
        signaling.incoming.finish()
        #expect(signaling.sent.withLock { $0 } == [.answer("v=0 child")])
        #expect(signaling.closes.withLock { $0 } == 1)
        #expect(events.withLock { $0 } == [.viewerConnected])
    }

    @Test func aChildThatEndsWithoutDoneFailsWithItsError() async throws {
        let process = MacScreenStreamProcess()
        try process.start { stdin, stdout, stderr in
            try MacScreenHelper.spawn(URL(fileURLWithPath: "/bin/sh"), ["-c", "read setup; echo 'no capture permission' >&2; sleep 0.2"],
                                      stdin: stdin, stdout: stdout, stderr: stderr)
        }
        let signaling = RecordingSignaling()
        await #expect(throws: MacScreenStreamProcess.Failed.self) {
            try await process.serve(signaling, name: "Mac", viewOnly: true, excluded: []) { _, _ in }
        }
        signaling.incoming.finish()
    }

    /// The child's side: exclusions apply before the host starts, signals and ICE answers reach it,
    /// and `done` follows the host's serve.
    final class FakeHost: MacScreenStreamServing {
        let excludedAtStart: Set<CGWindowID>
        let received = Mutex<[ScreenSignal]>([])
        let ice = Mutex<[ICEServerConfig]>([])
        let disconnects = Mutex(0)

        init(excludedAtStart: Set<CGWindowID>) {
            self.excludedAtStart = excludedAtStart
        }

        func serve(_ signaling: any ScreenSignaling) async throws {
            let servers = try await signaling.iceServers()
            ice.withLock { $0 = servers }
            try await signaling.send(.answer("v=0 host"))
            for try await signal in signaling.messages() {
                received.withLock { $0.append(signal) }
                if signal == .bye { break }
            }
            signaling.close()
        }

        func disconnectViewer() { disconnects.withLock { $0 += 1 } }
    }

    @Test func theChildSessionServesFromTheLines() async throws {
        let written = Mutex<[MacScreenStreamLine]>([])
        let host = Mutex<FakeHost?>(nil)
        let (finished, finish) = AsyncStream.makeStream(of: Void.self)
        let session = MacScreenStreamChildSession(write: { line in written.withLock { $0.append(line) } }, makeHost: { _, exclusions, _ in
            let made = FakeHost(excludedAtStart: exclusions.ids)
            host.withLock { $0 = made }
            return made
        }, finished: { finish.yield(); finish.finish() })
        session.receive(MacScreenStreamLine(setup: .init(name: "Mac", viewOnly: false, endsSessionOnClose: true), excludeWindows: [3, 5]))
        // The host asks for ICE servers first: answer its request.
        let request = try await Self.waitFor { written.withLock { $0.compactMap(\.iceRequest).first } }
        session.receive(MacScreenStreamLine(ice: .init(id: request, servers: [ICEServerConfig(urls: ["stun:a"])])))
        session.receive(MacScreenStreamLine(excludeWindows: [4]))
        session.receive(MacScreenStreamLine(signal: .init(.offer("v=0 viewer"))))
        session.receive(MacScreenStreamLine(signal: .init(.bye)))
        for await _ in finished { break }
        let made = try #require(host.withLock { $0 })
        #expect(made.excludedAtStart == [3, 5])
        #expect(session.exclusions.ids == [4])
        #expect(made.ice.withLock { $0 } == [ICEServerConfig(urls: ["stun:a"])])
        #expect(made.received.withLock { $0 } == [.offer("v=0 viewer"), .bye])
        let lines = written.withLock { $0 }
        #expect(lines.compactMap { $0.signal?.signal } == [.answer("v=0 host")])
        #expect(lines.contains { $0.close == true })
        #expect(lines.last?.done == MacScreenStreamLine.Done())
    }

    @Test func theChildEndsWithoutASetupWhenItsInputCloses() async {
        let (finished, finish) = AsyncStream.makeStream(of: Void.self)
        let session = MacScreenStreamChildSession(write: { _ in }, makeHost: { _, exclusions, _ in FakeHost(excludedAtStart: exclusions.ids) },
                                                  finished: { finish.yield(); finish.finish() })
        session.inputEnded()
        for await _ in finished { break }
    }

    /// Polls `read` until it is non-nil, for up to 5 s.
    static func waitFor<T>(_ read: () -> T?) async throws -> T {
        for _ in 0 ..< 500 {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}
