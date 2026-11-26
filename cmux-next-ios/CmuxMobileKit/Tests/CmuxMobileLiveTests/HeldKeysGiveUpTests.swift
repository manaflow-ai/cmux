import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Keys held for the attach are dropped, and the person told ("not sent"), only when the
/// reconnect gives up: its retries ran out, the Mac was offline for `inputHoldLimit` (10 s),
/// `inputHoldBytes` (16 KB) were queued, or `inputHoldCeiling` (60 s) passed for an app
/// suspended with keys queued (termfix-r13 D5: no command runs minutes late). Until then the
/// screen hears how many wait (`.inputHeld`), and the person may discard them.
/// The Mac-offline and 16 KB cases at the session are
/// `DaemonTerminalSessionTests.keysTypedWhileTheMacStaysOfflinePastTheHoldAreDroppedWithANotice`
/// and `theHoldIsBoundedByBytes`; all four are checked here too.
@MainActor @Suite struct HeldKeysGiveUpTests {
    @MainActor final class Rig {
        let daemon = FakeTerminalDaemon()
        let channels = ChannelLog()
        let session: DaemonTerminalSession
        var clock: TimeInterval = 1000
        var events: [TerminalSessionEvent] = []

        init() {
            let daemon = daemon
            let channels = channels
            let link = MockMacLink { service, line in daemon.respond(service, line) }
            session = DaemonTerminalSession(surface: 7) {
                let channel = try await link.openChannel(service: "daemon", args: [:])
                channels.append(channel)
                return DaemonClient(channel: channel)
            }
            session.now = { [unowned self] in self.clock }
        }

        var typed: Data {
            daemon.recorded.filter { $0["cmd"] as? String == "send" }
                .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } }
                .reduce(into: Data()) { $0.append($1) }
        }

        var notSent: [Int] { events.compactMap { if case .inputNotSent(let n) = $0 { n } else { nil } } }
        var held: [Int] { events.compactMap { if case .inputHeld(let n) = $0 { n } else { nil } } }

        /// Attached, then the link drops (`beforeTheDrop` runs while attached).
        func attachedThenDown(beforeTheDrop: () -> Void = {}) async throws {
            session.start { [unowned self] in self.events.append($0) }
            try await HeldKeysGiveUpTests.waitUntil { self.session.isAttached }
            beforeTheDrop()
            await channels.last?.close(code: "link_closed", reason: "link dropped")
            try await HeldKeysGiveUpTests.waitUntil { !self.session.isAttached }
        }

        /// The link is back: whatever the attach sends and says lands.
        func reattach() async throws {
            daemon.failNextAttaches = 0
            session.reconnect()
            try await HeldKeysGiveUpTests.waitUntil { self.session.isAttached }
            for _ in 0..<50 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(50)) // test: the attach's drain reaches the fake daemon
        }
    }

    static func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// While keys wait, the screen hears how many (the composer's pending line); the attach clears it.
    @Test func heldKeysAreReportedUntilTheAttachSendsThem() async throws {
        let rig = Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        rig.session.send(Data("ls".utf8))
        rig.session.send(Data("\r".utf8))
        #expect(rig.held == [2, 3])
        try await rig.reattach()
        #expect(rig.typed == Data("ls\r".utf8))
        #expect(rig.held.last == 0)
        #expect(rig.notSent.isEmpty)
    }

    /// Discard: none of the held keys is sent, nothing says "not sent", and typing goes on.
    @Test func discardedHeldKeysNeverGo() async throws {
        let rig = Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        rig.session.send(Data("rm -rf build\r".utf8))
        rig.session.discardHeldInput()
        #expect(rig.held.last == 0)
        rig.session.send(Data("ls\r".utf8))
        try await rig.reattach()
        #expect(rig.typed == Data("ls\r".utf8), "a discarded key went, or a later one did not")
        #expect(rig.notSent.isEmpty)
    }

    /// (1) The reconnect gives up (its retries ran out): the held keys are dropped then, and said.
    @Test func keysHeldWhenTheReconnectGivesUpAreDroppedWithANotice() async throws {
        let rig = Rig()
        defer { rig.session.stop() }
        // Every reattach fails, on a short backoff: the session's own reattach gives up.
        try await rig.attachedThenDown {
            rig.daemon.failNextAttaches = 100
            rig.session.reattachBackoff = [0.02, 0.02]
        }
        rig.session.send(Data("ls\r".utf8))
        try await Self.waitUntil { !rig.notSent.isEmpty }
        if case .failed = rig.session.connectionState {} else {
            Issue.record("the reconnect never gave up: \(rig.session.connectionState)")
        }
        #expect(rig.notSent == [3])
        #expect(rig.held.last == 0)
        try await rig.reattach()
        #expect(rig.typed.isEmpty, "keys from a reconnect that gave up ran later")
    }

    /// (2) The Mac offline for 10 s: dropped, and said.
    @Test func keysHeldWhileTheMacIsOfflineForTheHoldAreDroppedWithANotice() async throws {
        let rig = Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        rig.session.send(Data("ls\r".utf8))
        rig.session.setMacOffline(true)
        rig.clock += DaemonTerminalSession.inputHoldLimit - 1
        rig.session.setMacOffline(false)
        #expect(rig.notSent.isEmpty, "dropped before the Mac was offline for the hold")
        rig.session.setMacOffline(true)
        rig.clock += DaemonTerminalSession.inputHoldLimit
        rig.session.setMacOffline(false)
        #expect(rig.notSent == [3])
        try await rig.reattach()
        #expect(rig.typed.isEmpty, "keys from a 10 s outage ran later")
    }

    /// (3) 16 KB queued: dropped at once, and said.
    @Test func sixteenKilobytesHeldAreDroppedWithANotice() async throws {
        let rig = Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        rig.session.send(Data("a".utf8))
        rig.session.send(Data(repeating: UInt8(ascii: "x"), count: DaemonTerminalSession.inputHoldBytes))
        #expect(DaemonTerminalSession.inputHoldBytes == 16 * 1024)
        #expect(rig.notSent == [DaemonTerminalSession.inputHoldBytes + 1])
        #expect(rig.held.last == 0)
        try await rig.reattach()
        #expect(rig.typed.isEmpty, "a held 16 KB ran later")
    }

    /// (4) The 60 s ceiling for an app suspended with keys queued: its next attach drops
    /// them, and says so, rather than type them a minute or more late (termfix-r13 D5).
    @Test func keysHeldPastTheCeilingAreDroppedAtTheNextAttach() async throws {
        let rig = Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        rig.session.send(Data("ls\r".utf8))
        // Suspended: no timer ran, the clock moved on.
        rig.clock += DaemonTerminalSession.inputHoldCeiling + 1
        #expect(DaemonTerminalSession.inputHoldCeiling == 60)
        try await rig.reattach()
        #expect(rig.notSent == [3])
        #expect(rig.typed.isEmpty, "keys typed before a minute-long suspension ran after it")
    }
}
