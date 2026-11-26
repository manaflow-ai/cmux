import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Back from minutes away, a terminal's attach runs while the link still redials. It must wait
/// for the link ("Reattaching…", keys held, Send taken), never spend its retries on "no link" and
/// give up into "Can't reach this terminal" with Send refused and the held keys dropped.
/// Leo, 2026-11-24: "The like multi-second long reattach where like the entire thing is somehow
/// grayed out and I can't interact with anything at all."
@MainActor @Suite struct AttachWaitsForTheLinkTests {
    @MainActor final class Rig {
        let daemon = FakeTerminalDaemon()
        let channels = ChannelLog()
        let session: DaemonTerminalSession
        /// The link is served (false: every open throws `no-link`, as `LiveCoordinator`'s does).
        let link = LinkFlag()
        var linkUp: Bool {
            get { link.up }
            set { link.up = newValue }
        }
        var events: [TerminalSessionEvent] = []

        init() {
            let daemon = daemon
            let channels = channels
            let flag = link
            let mac = MockMacLink { service, line in daemon.respond(service, line) }
            session = DaemonTerminalSession(surface: 7) {
                guard flag.up else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
                let channel = try await mac.openChannel(service: "daemon", args: [:])
                channels.append(channel)
                return DaemonClient(channel: channel)
            }
        }

        var typed: Data {
            daemon.recorded.filter { $0["cmd"] as? String == "send" }
                .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } }
                .reduce(into: Data()) { $0.append($1) }
        }

        var notSent: [Int] { events.compactMap { if case .inputNotSent(let n) = $0 { n } else { nil } } }
        var held: [Int] { events.compactMap { if case .inputHeld(let n) = $0 { n } else { nil } } }
    }

    /// Polls `condition` up to 30 s. The kit's tests run in parallel: on 2026-11-25 (job
    /// 139327571649) the synchronous `onlyAMissingLinkWaits` took 8 s there, and a 3 s bound
    /// ran out before the reattach sent the held key. A path that never finishes still fails here.
    static func waitUntil(_ what: String, attempts: Int = 3000, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(what) within \(attempts / 100) s")
    }

    @Test func anAttachWithNoLinkWaitsForItInsteadOfGivingUp() async throws {
        let rig = Rig()
        defer { rig.session.stop() }
        rig.session.reattachBackoff = [0.02, 0.02]
        rig.session.start { [weak rig] in rig?.events.append($0) }
        try await Self.waitUntil("the first attach") { rig.session.isAttached }
        // Backgrounded: the link goes; the channel ends with it.
        rig.linkUp = false
        await rig.channels.last?.close(code: "link_closed", reason: "link dropped")
        try await Self.waitUntil("the channel's end detaches") { !rig.session.isAttached }
        // The channel's own self-reattach (first backoff step) finds no link and stops.
        try await Task.sleep(for: .milliseconds(100)) // test: let the self-reattach settle first
        // In front again: the tab's attach runs while the link still redials.
        rig.session.reconnect()
        // Longer than every retry of the backoff: base gave up by now.
        try await Task.sleep(for: .milliseconds(300)) // test: past the short backoff's two retries
        #expect(rig.session.connectionState == .reattaching(mac: nil), "gave up on an attach that only lacked the link")

        // The first key, at once: taken (held for the attach), not refused.
        let typedAt = ContinuousClock.now
        rig.session.send(Data("ls\r".utf8))
        #expect(ContinuousClock.now - typedAt < .milliseconds(100))
        #expect(rig.notSent.isEmpty, "the first key after the return was refused")
        #expect(rig.held.last == 3)

        // The link is back: its return reattaches the session, and the held key goes.
        rig.linkUp = true
        rig.session.reconnect()
        try await Self.waitUntil("the reattach") { rig.session.isAttached }
        try await Self.waitUntil("the held key goes") { rig.typed == Data("ls\r".utf8) }
        #expect(rig.typed == Data("ls\r".utf8))
        #expect(rig.notSent.isEmpty)
    }

    /// A first attach on a cold launch: the terminal's open reads "no link" just before the link
    /// is served, and the link's `reconnect()` of every terminal comes while that attach is still
    /// out. Before, that reconnect was dropped (`attaching`) and the attach then waited for a
    /// link that had already come: the page's skeleton for good (Aziz's TestFlight, 2026-11-25).
    @Test func aLinkThatComesDuringTheFirstAttachIsNotMissed() async throws {
        let daemon = FakeTerminalDaemon()
        let gate = OpenGate()
        let flag = LinkFlag()
        flag.up = false
        let mac = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            let up = flag.up
            // The first open read the link (down) and is still on its way back.
            await gate.passFirst()
            guard up else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            return DaemonClient(channel: try await mac.openChannel(service: "daemon", args: [:]))
        }
        defer { session.stop() }
        session.reattachBackoff = [0.02, 0.02]
        session.start { _ in }
        try await Self.waitUntil("the first open is out") { gate.waiting }
        // The link is served now, and the coordinator reconnects every terminal of the Mac.
        flag.up = true
        session.reconnect()
        // The first open comes back with "no link".
        gate.open()
        try await Self.waitUntil("the attach on the link that came") { session.isAttached }
        #expect(session.connectionState == .attached)
    }

    @Test func onlyAMissingLinkWaits() {
        #expect(DaemonTerminalSession.waitsForTheLink(LinkError(code: "no-link", message: "Not connected to the Mac")))
        #expect(!DaemonTerminalSession.waitsForTheLink(LinkError(code: "unpaired", message: "")))
    }
}

/// Whether the test's link is served, read from the session's open.
final class LinkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var up: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Holds the session's first open until the test lets it go; later opens pass at once.
final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    private var held: CheckedContinuation<Void, Never>?
    private var released = false

    /// The first open is held now.
    var waiting: Bool { lock.withLock { held != nil } }

    func passFirst() async {
        let hold = lock.withLock { () -> Bool in
            defer { first = false }
            return first && !released
        }
        guard hold else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                held = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}
