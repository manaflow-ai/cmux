#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import QuartzCore
import Testing
import UIKit
@testable import CmuxMobileLive
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12, on LTE: "wack reconnection state / just show the cache".
///
/// His phone showed a terminal tab wiped to black with the raw words
/// "[daemon channel closed]" at the top, a skeleton and a centered
/// "Connecting to cosmic-gray… · Retry" pill. The tab had a fresh session (a
/// tab back from the warm set, or a relaunch) holding its cached frame; its
/// first attach failed on the dropped link and wrote the transport error into
/// the terminal stream. Those bytes read as live output: the model turned
/// "attached", the page dropped its cached frame for the blank surface, and
/// the frame saver stored that blank page over the good one.
///
/// The harness drives the real screen (`TerminalViewController`, Ghostty
/// surface) over a real `DaemonTerminalSession` on a fake Mac, forces the
/// disconnect, and reports frames cleared, transport bytes written and the
/// time the page showed neither its cache nor live rows.
@MainActor
@Suite(.serialized) struct ReconnectShowsCacheTests {
    /// Forwards a session's events to the screen and records them.
    @MainActor
    final class Recording: TerminalSession {
        let inner: DaemonTerminalSession
        private(set) var events: [TerminalSessionEvent] = []
        init(_ inner: DaemonTerminalSession) { self.inner = inner }
        var programName: String { inner.programName }
        var isAlternateScreen: Bool { inner.isAlternateScreen }
        var remoteRows: Int? { inner.remoteRows }
        var remoteColumns: Int? { inner.remoteColumns }
        var connectionState: TerminalConnectionState { inner.connectionState }
        var hostGridOwnerName: String? { inner.hostGridOwnerName }
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
            inner.start { [weak self] event in
                self?.events.append(event)
                handler(event)
            }
        }
        func send(_ bytes: Data) { inner.send(bytes) }
        func resize(columns: Int, rows: Int) { inner.resize(columns: columns, rows: rows) }
        func stop() { inner.stop() }
        func setOutputPaused(_ paused: Bool) { inner.setOutputPaused(paused) }
        func setClaimsSize(_ claims: Bool) { inner.setClaimsSize(claims) }
        /// Output written before the first attach: never the Mac's, so transport text.
        var bytesBeforeAttach: Int {
            var total = 0
            for event in events {
                if event == .connection(.attached) { break }
                if case .output(let data) = event { total += data.count }
            }
            return total
        }
    }

    struct Numbers: CustomStringConvertible {
        var framesCleared = 0
        var transportBytes = 0
        var blankMs = 0.0
        var timeToContentMs = 0.0
        var description: String {
            "frames_cleared=\(framesCleared) transport_bytes=\(transportBytes) blank_ms=\(Int(blankMs)) time_to_content_ms=\(Int(timeToContentMs))"
        }
    }

    static func frame() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 390, height: 300)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 300))
        }
    }

    /// One forced disconnect on a fresh session holding a cached frame:
    /// the first attach fails and gives up (the link dropped), the link is
    /// down for 400 ms, then it comes back and the session attaches.
    func forcedDisconnect() async throws -> (Numbers, Recording, TerminalModel) {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        daemon.failNextAttaches = 1
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let inner = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        inner.macName = "cosmic-gray"
        // The link is gone: no retry lands before it is back.
        inner.reattachBackoff = []
        let session = Recording(inner)
        let model = TerminalModel(session: session, artifactSource: UnavailableArtifactSource(), title: "interim-coord")
        model.restoreLastFrame(Self.frame())
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            inner.stop()
        }

        var numbers = Numbers()
        var hadFrame = model.coldFrame != nil
        var blankSince: CFTimeInterval?
        let started = CACurrentMediaTime()
        // Samples the page each 5 ms: cleared frames and blank time.
        func sample() {
            let now = CACurrentMediaTime()
            let hasFrame = model.coldFrame != nil
            if hadFrame, !hasFrame, !inner.isAttached { numbers.framesCleared += 1 }
            hadFrame = hasFrame
            let blank = !hasFrame && !inner.isAttached
            if blank, blankSince == nil { blankSince = now }
            if !blank, let since = blankSince { numbers.blankMs += (now - since) * 1000; blankSince = nil }
        }
        func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
            let deadline = CACurrentMediaTime() + seconds
            while !condition(), CACurrentMediaTime() < deadline {
                sample()
                try await Task.sleep(for: .milliseconds(5)) // test: samples the page until a deadline
            }
            sample()
        }

        // The first attach fails (the dropped link) and gives up.
        try await waitUntil { if case .failed = inner.connectionState { true } else { false } }
        #expect(!inner.isAttached)
        // The outage.
        let outageEnd = CACurrentMediaTime() + 0.4
        try await waitUntil(10) { CACurrentMediaTime() >= outageEnd }
        // The link is back (`finishServing` reconnects every open terminal).
        let back = CACurrentMediaTime()
        inner.reconnect()
        try await waitUntil { inner.isAttached && model.coldFrame == nil }
        numbers.timeToContentMs = model.coldFrame == nil ? (CACurrentMediaTime() - back) * 1000 : -1
        if let since = blankSince { numbers.blankMs += (CACurrentMediaTime() - since) * 1000 }
        numbers.transportBytes = session.bytesBeforeAttach
        print("reconnect-harness: \(numbers) total_ms=\(Int((CACurrentMediaTime() - started) * 1000))")
        return (numbers, session, model)
    }

    /// The forced disconnect keeps the cached frame on screen until the Mac's
    /// rows are drawn, and writes nothing of the transport into the terminal.
    @Test func aForcedDisconnectKeepsTheCachedFrameAndWritesNoTransportText() async throws {
        let (numbers, session, model) = try await forcedDisconnect()
        #expect(numbers.transportBytes == 0, "transport text reached the terminal stream: \(numbers)")
        #expect(numbers.framesCleared == 0, "the cached frame was dropped before the Mac's rows: \(numbers)")
        #expect(numbers.blankMs == 0, "the page showed neither its cache nor live rows: \(numbers)")
        let text = session.events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(!text.contains("daemon channel closed") && !text.contains("unknown surface") && !text.contains("Can't"),
                "transport words in the stream: \(text.debugDescription)")
        // The same model and session went from failed to attached: nothing was rebuilt.
        #expect(model.session === session)
        #expect(model.connectionState.isAttached)
    }
}

/// The attach paths say nothing into the terminal stream on failure, first
/// attach or reattach; the state carries it.
@MainActor
@Suite struct NoTransportTextTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private static func output(_ events: [TerminalSessionEvent]) -> String {
        events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
    }

    @Test(arguments: [false, true])
    func aFailedAttachWritesNothingIntoTheTerminal(wasAttached: Bool) async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        defer { session.stop() }
        session.reattachBackoff = []
        session.macName = "cosmic-gray"
        var events: [TerminalSessionEvent] = []
        if !wasAttached { daemon.failNextAttaches = 1 }
        session.start { events.append($0) }
        var before = 0
        if wasAttached {
            try await waitUntil { session.isAttached }
            await channels.last?.close(code: "eof", reason: "daemon channel closed")
            try await waitUntil { !session.isAttached }
            before = events.count
            daemon.failNextAttaches = 1
            session.reconnect()
        }
        try await waitUntil { if case .failed = session.connectionState { true } else { false } }
        #expect(Self.output(Array(events[before...])).isEmpty, "bytes written on a failed attach: \(Self.output(Array(events[before...])).debugDescription)")
        // Plain words for the composer, never the transport's error.
        guard case .failed(let message) = session.connectionState else { return }
        #expect(message.contains("cosmic-gray"))
        #expect(!message.contains("unknown surface") && !message.contains("channel"))
    }

    /// A fresh session's first attach rides out a blip like a reattach: it
    /// retries and attaches, never giving up at the first failure.
    @Test func aFirstAttachRetriesThroughABlip() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.failNextAttaches = 2
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        defer { session.stop() }
        session.reattachBackoff = [0.02, 0.02, 0.02]
        var states: [TerminalConnectionState] = []
        session.start { event in if case .connection(let state) = event { states.append(state) } }
        try await waitUntil { session.isAttached }
        #expect(!states.contains { if case .failed = $0 { true } else { false } }, "gave up on a blip: \(states)")
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 3)
    }
}
#endif
