#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import Testing
import UIKit
@testable import CmuxMobileLive
@testable import CmuxMobileTerminal

/// The session's clock, moved by the test past the hold limit.
final class UnsentKeysClock {
    var now: TimeInterval = 1000
}

/// Leo, 2026-11-14, on "Keys typed while your Mac was unreachable were not
/// sent.": "This one message seems to show up unnecessarily Like all I did
/// was navigate away and then it showed this, but I didn't type anything".
///
/// The notice is said only when keys the person typed, pressed or pasted were
/// dropped. A scroll's wheel reports, a tap's click report, a key release and
/// Ghostty's own replies (device, cursor, focus, visibility and size reports)
/// are no keys: through an outage they are dropped without it.
///
/// The real screen (`TerminalViewController`, Ghostty surface) over a real
/// `DaemonTerminalSession` on a fake Mac, with a full-screen app that asked
/// for mouse, focus, visibility and size reports.
@MainActor
@Suite(.serialized) struct UnsentKeysNoticeTests {
    @MainActor
    struct Rig {
        let daemon: FakeTerminalDaemon
        let channels: ChannelLog
        let session: DaemonTerminalSession
        let model: TerminalModel
        let screen: TerminalViewController
        let window: UIWindow
        let clock: UnsentKeysClock

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            session.stop()
        }

        /// The keys the Mac's terminal got (`send`), in order.
        var sent: Data {
            daemon.recorded.filter { $0["cmd"] as? String == "send" }
                .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } }
                .reduce(into: Data()) { $0.append($1) }
        }

        /// The link drops: the session is detached.
        func dropLink() async throws {
            await channels.last?.close(code: "link_closed", reason: "outage")
            try await UnsentKeysNoticeTests.waitUntil { !session.isAttached }
            #expect(!session.isAttached)
        }

        /// The outage outlasts the hold limit, then the link is back.
        func reattachAfterTheHold() async throws {
            clock.now += DaemonTerminalSession.inputHoldLimit + 1
            session.reconnect()
            try await UnsentKeysNoticeTests.waitUntil { session.isAttached }
            #expect(session.isAttached)
            // Whatever the reattach drains and reports lands.
            for _ in 0..<50 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(100)) // test: the reattach's events reach the model
        }
    }

    static func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the screen until a deadline
        }
    }

    /// A full-screen app attached on screen: it asked for mouse clicks and
    /// wheels (1000), focus (1004), visibility (2033) and in-band size (2048)
    /// reports.
    static func makeRig() async throws -> Rig {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1004h\u{1B}[?2033h\u{1B}[?2048hTUI"
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        let clock = UnsentKeysClock()
        session.now = { clock.now }
        let model = TerminalModel(session: session, artifactSource: UnavailableArtifactSource(), title: "unsent-keys")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        let rig = Rig(daemon: daemon, channels: channels, session: session, model: model, screen: screen, window: window, clock: clock)
        try await waitUntil { session.isAttached && model.isTUI && screen.surface.capturesMouse }
        try #require(session.isAttached, "the session never attached")
        try #require(screen.surface.capturesMouse, "the app's mouse mode never reached Ghostty")
        return rig
    }

    /// A drag's wheel and its fling, as `TerminalTUIScrollController` sends them.
    static func fling(_ surface: TerminalSurfaceView) {
        let at = CGPoint(x: 120, y: 300)
        surface.scrollWheel(at: at, deltaY: 160, momentum: .none)
        surface.scrollWheel(at: at, deltaY: 240, momentum: .began)
        for _ in 0..<6 { surface.scrollWheel(at: at, deltaY: 120, momentum: .changed) }
        surface.scrollWheel(at: at, deltaY: 0, momentum: .ended)
    }

    /// (a) Leo's flow: a flick in the app, the page left while its fling
    /// still runs and the link drops (the app goes to the background), the
    /// page comes back and the terminal reattaches. Nothing was typed: no
    /// notice, and no scroll from before the outage is replayed into the app.
    @Test func navigatingAwayAndBackWithNoTypingSaysNothing() async throws {
        let rig = try await Self.makeRig()
        defer { rig.close() }
        let surface = rig.screen.surface

        // The flick starts on the page.
        Self.fling(surface)
        try await rig.dropLink()
        let sentBefore = rig.sent

        // The page leaves (another tab, the grid, the app in the background):
        // the surface leaves the window (a visibility report), the fling's
        // last frames still go out, and the app asks for reports Ghostty answers.
        rig.window.rootViewController = UIViewController()
        Self.fling(surface)
        surface.feed(Data("\u{1B}[c\u{1B}[6n\u{1B}[?1004h".utf8))
        try await Task.sleep(for: .milliseconds(200)) // test: Ghostty's replies come back on the main queue

        // The page comes back (a new size report) and the link with it.
        rig.window.rootViewController = rig.screen
        try await Task.sleep(for: .milliseconds(200)) // test: the page lays out again
        try await rig.reattachAfterTheHold()

        #expect(rig.model.composerNotice == nil, "said keys were not sent with nothing typed: \(rig.model.composerNotice ?? "")")
        #expect(rig.sent == sentBefore, "a scroll or report from the outage reached the app after the reattach")

        // Typing works after the reattach, and goes.
        surface.perform([.text("x")])
        try await Self.waitUntil { rig.sent.count > sentBefore.count }
        #expect(rig.sent.suffix(1) == Data("x".utf8))
        #expect(rig.model.composerNotice == nil)
    }

    /// (b) Keys the person typed while the Mac was unreachable, dropped past
    /// the hold: the notice says so, and they never run.
    @Test func keysTypedDuringAnOutageSayTheyWereNotSent() async throws {
        let rig = try await Self.makeRig()
        defer { rig.close() }
        try await rig.dropLink()
        let sentBefore = rig.sent

        rig.screen.surface.perform([.text("ls")])
        try await rig.reattachAfterTheHold()

        try await Self.waitUntil { rig.model.composerNotice != nil }
        #expect(rig.model.composerNotice == TerminalConnectionState.inputNotSentNotice)
        #expect(rig.sent == sentBefore, "keys typed in the outage ran after it")
    }

    /// (c) Only what the terminal wrote by itself during the outage: Ghostty's
    /// answers to the app's device and cursor queries, a focus report, a tap's
    /// click report and a scroll. Dropped, with no notice, and the person's
    /// keys after the reattach are not refused.
    @Test func onlySyntheticInputDroppedInAnOutageSaysNothing() async throws {
        let rig = try await Self.makeRig()
        defer { rig.close() }
        let surface = rig.screen.surface
        try await rig.dropLink()
        let sentBefore = rig.sent

        surface.feed(Data("\u{1B}[c\u{1B}[6n\u{1B}[>c".utf8))
        surface.onInput?(Data("\u{1B}[O".utf8))
        #expect(surface.click(at: CGPoint(x: 60, y: 200)), "the app's mouse mode is gone")
        Self.fling(surface)
        try await Task.sleep(for: .milliseconds(200)) // test: Ghostty's replies come back on the main queue
        try await rig.reattachAfterTheHold()

        #expect(rig.model.composerNotice == nil, "said keys were not sent with nothing typed: \(rig.model.composerNotice ?? "")")
        #expect(rig.sent == sentBefore, "a report from the outage was sent after the reattach")

        surface.perform([.text("y")])
        try await Self.waitUntil { rig.sent.count > sentBefore.count }
        #expect(rig.sent.suffix(1) == Data("y".utf8), "the person's key after the reattach was refused")
        #expect(rig.model.composerNotice == nil)
    }
}
#endif
