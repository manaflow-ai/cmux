import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A cmux-tui daemon stand-in for one PTY surface: answers `identify`,
/// `attach-surface` (vt-state replay first, then the reply), `send` and
/// `resize-surface`, and records every command.
final class FakeTerminalDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String: Any]] = []
    /// The next N attaches answer "unknown surface" (a Mac host that just restarted).
    var failNextAttaches = 0
    /// `identify` advertises attach-initial-size.
    var initialSize = false
    /// `identify` advertises size-lease-v1.
    var sizeLease = false
    /// `identify` advertises shared-sizing-v1: the attach reply carries the
    /// view's participant and size state, and a newer `size-state` follows.
    var sharedSizing = false
    /// The owners of the size state the attach sends (shared sizing).
    var owners = ["c2"]
    /// The Mac's sizing policy (`get-host-size-policy`, `set-host-size-policy`).
    var hostPolicy: [String: Any] = ["mode": "smallest", "order": [String]()]
    /// The surface the terminal is on now (a daemon restart renumbers it).
    var liveSurface = 7
    /// `resolve-terminal` answers: terminal id to its surface (nil: the
    /// daemon does not know the command).
    var terminals: [String: Int]? = nil
    /// The next N `resolve-terminal` answers have a null surface (restoring).
    var restoring = 0
    /// Terminals whose process exited while no surface shows them:
    /// `resolve-terminal` answers a null surface with lifecycle `exited`.
    var exited: Set<String> = []
    /// The next N `resolve-terminal` answers are terminal_not_found (a registry
    /// still loading right after the Mac app restarted).
    var missing = 0
    /// The `vt-state` replay an attach sends.
    var replay = "hello\r\n$ "
    /// Live output right after the attach reply (nil: none).
    var afterAttach: String? = "\u{1B}[?1049hTUI"
    /// `send` is recorded but never answered (its reply lost on the way).
    var unansweredSends = false

    var recorded: [[String: Any]] { lock.withLock { commands } }

    func respond(_ service: String, _ data: Data) -> [Data] {
        // A batch (`DaemonClient.requests`) is several lines in one write.
        data.split(separator: 0x0A).flatMap { respondLine(service, Data($0)) }
    }

    private func respondLine(_ service: String, _ line: Data) -> [Data] {
        guard service == "daemon", let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return [] }
        lock.withLock { commands.append(object) }
        func reply(_ data: [String: Any] = [:]) -> Data {
            Self.line(["id": id, "ok": true, "data": data])
        }
        switch cmd {
        case "send" where lock.withLock({ unansweredSends }):
            return []
        case "identify" where initialSize || sizeLease || sharedSizing:
            return [reply(["capabilities": (initialSize ? ["attach-initial-size"] : []) + (sizeLease ? ["size-lease-v1"] : [])
                    + (sharedSizing ? ["shared-sizing-v1", "host-size-policy-v1"] : [])])]
        case "get-host-size-policy":
            return [reply(["policy": lock.withLock { hostPolicy }, "mac_participants": object["surface"] == nil ? [String]() : ["c1"]])]
        case "set-host-size-policy":
            guard var policy = object["policy"] as? [String: Any] else {
                return [Self.line(["id": id, "ok": false, "error": "bad request: policy"])]
            }
            lock.withLock {
                if policy["order"] == nil { policy["order"] = hostPolicy["order"] }
                hostPolicy = policy
            }
            return [reply(["policy": policy])]
        case "resolve-terminal":
            guard let terminals = lock.withLock({ self.terminals }) else {
                return [Self.line(["id": id, "ok": false, "error": "unknown command resolve-terminal"])]
            }
            let restoringNow: Bool = lock.withLock {
                guard restoring > 0 else { return false }
                restoring -= 1
                return true
            }
            if restoringNow { return [reply(["surface": NSNull(), "terminal_id": object["terminal_id"] ?? ""])] }
            if let terminal = object["terminal_id"] as? String, lock.withLock({ exited.contains(terminal) }) {
                return [reply(["surface": NSNull(), "terminal_id": terminal, "lifecycle": "exited"])]
            }
            let missingNow: Bool = lock.withLock {
                guard missing > 0 else { return false }
                missing -= 1
                return true
            }
            if missingNow { return [Self.line(["id": id, "ok": false, "error": "terminal_not_found"])] }
            guard let id2 = object["terminal_id"] as? String, let surface = terminals[id2] else {
                return [Self.line(["id": id, "ok": false, "error": "terminal_not_found"])]
            }
            return [reply(["surface": surface, "terminal_id": id2])]
        case "attach-surface":
            let fail: Bool = lock.withLock {
                guard failNextAttaches > 0 else { return false }
                failNextAttaches -= 1
                return true
            }
            if fail {
                // The replay a refusing daemon never sends; a stray event first, then the refusal.
                return [Self.line(["event": "output", "surface": 7, "data": Data("stale".utf8).base64EncodedString()]),
                        Self.line(["id": id, "ok": false, "error": "unknown surface 7"])]
            }
            let live = lock.withLock { liveSurface }
            guard object["surface"] as? Int == live else {
                return [Self.line(["id": id, "ok": false, "error": "unknown surface \(object["surface"] as? Int ?? -1)"])]
            }
            let (shared, owners) = lock.withLock { (sharedSizing, self.owners) }
            func sizeState(_ generation: Int) -> [String: Any] {
                ["generation": generation, "cols": 80, "rows": 24, "reason": "smallest", "owners": owners,
                 "policy": ["mode": "smallest", "priority": [], "fixed": NSNull()],
                 "participants": [["id": "c1", "device_kind": "mac", "viewport": ["cols": 80, "rows": 24], "counts": true],
                                  ["id": "c2", "device_kind": "iphone", "device_id": "ios-1", "viewport": ["cols": 80, "rows": 30], "counts": true]]]
            }
            return [
                Self.line(["event": "vt-state", "surface": live, "cols": 80, "rows": 24,
                           "data": Data(replay.utf8).base64EncodedString()]),
                reply(shared ? ["lease": "l1", "participant": "c2", "size_state": sizeState(1)] as [String: Any] : ["lease": "l1"]),
            ] + (shared ? [Self.line(["event": "size-state", "surface": live, "self_participant": "c2", "state": sizeState(2)])] : [])
                + (afterAttach.map { [Self.line(["event": "output", "surface": live, "data": Data($0.utf8).base64EncodedString()])] } ?? []) + [
                Self.line(["event": "output", "surface": 8, "data": Data("other".utf8).base64EncodedString()]),
            ]
        default:
            return [reply()]
        }
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

@MainActor @Suite struct DaemonTerminalSessionTests {
    @Test func attachesReplaysAndForwardsInput() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { events.contains(.alternateScreen(true)) }
        let output = events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        // A reset first (the mirror starts clean and places the Mac's screen), then the replay; surface 8 ignored.
        #expect(output == "\u{1B}chello\r\n$ \u{1B}[?1049hTUI")
        #expect(session.remoteRows == 24)
        #expect(session.isAlternateScreen)

        session.send(Data("ls\r".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        let send = try #require(daemon.recorded.first { $0["cmd"] as? String == "send" })
        #expect(send["surface"] as? Int == 7)
        #expect(send["bytes"] as? String == Data("ls\r".utf8).base64EncodedString())
        let resize = try #require(daemon.recorded.first { $0["cmd"] as? String == "resize-surface" })
        #expect(resize["cols"] as? Int == 54)
        #expect(resize["rows"] as? Int == 42)
        // The resize waited for the attach.
        let order = daemon.recorded.compactMap { $0["cmd"] as? String }
        #expect(order.firstIndex(of: "attach-surface")! < order.firstIndex(of: "resize-surface")!)
    }

    /// Keystrokes go on their own input-lane channel; resizes stay on the
    /// attach channel (geometry authority belongs to the attaching client).
    @Test func keystrokesRideTheInputLane() async throws {
        let main = FakeTerminalDaemon()
        let lane = FakeTerminalDaemon()
        let mainLink = MockMacLink { service, line in main.respond(service, line) }
        let laneLink = MockMacLink { service, line in lane.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, open: {
            DaemonClient(channel: try await mainLink.openChannel(service: "daemon", args: [:]))
        }, openInput: {
            DaemonClient(channel: try await laneLink.openInputChannel(service: "daemon", args: [:]))
        })
        session.start { _ in }
        session.resize(columns: 80, rows: 30)
        try await waitUntil { session.isAttached }
        // The lane opens just after the attach; wait until it carries a send.
        var typed = 0
        for _ in 0..<50 where !lane.recorded.contains(where: { $0["cmd"] as? String == "send" }) {
            session.send(Data("x".utf8))
            typed += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lane.recorded.contains { $0["cmd"] as? String == "send" })
        #expect(!lane.recorded.contains { $0["cmd"] as? String == "resize-surface" })
        #expect(main.recorded.contains { $0["cmd"] as? String == "resize-surface" })
        // Every keystroke arrived exactly once, across both channels.
        let sent = (main.recorded + lane.recorded).filter { $0["cmd"] as? String == "send" }
            .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } }
            .reduce(into: Data()) { $0.append($1) }
        try await waitUntil {
            (main.recorded + lane.recorded).filter { $0["cmd"] as? String == "send" }
                .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) }?.count }.reduce(0, +) == typed
        }
        #expect(sent.allSatisfy { $0 == UInt8(ascii: "x") })
    }

    /// TUI fast scroll: input does not wait for the last `send`'s reply.
    /// One small request at a time stalled a flick for the link's whole
    /// retransmission timeout (1 s, then 2 s) whenever a segment was lost
    /// over TURN; with the next batch already behind it, TCP repairs the loss
    /// from the duplicate ACKs within a few segments.
    @Test func inputDoesNotWaitForTheLastReply() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredSends = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        // A frozen clock: a slow host must not age these sends past `inputStallLimit`.
        session.now = { 1000 }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let sends = { daemon.recorded.filter { $0["cmd"] as? String == "send" }
            .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } } }
        session.send(Data("a".utf8))
        try await waitUntil { sends().count == 1 }
        session.send(Data("b".utf8))
        try await waitUntil { sends().count == 2 }
        session.send(Data("c".utf8))
        try await waitUntil { sends().count == 3 }
        // In order, each once.
        #expect(sends() == ["a", "b", "c"].map { Data($0.utf8) })
    }

    /// Review of the pipelined input: a `send` that was written and then
    /// lost its channel may already have been typed on the Mac. It is never
    /// sent again (a doubled Return runs a command twice), neither are the
    /// keys typed after it, and the screen is told.
    @Test func aWrittenSendIsNeverSentTwiceAfterTheChannelFails() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredSends = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var events: [TerminalSessionEvent] = []
        // A frozen clock: a slow host must not age these sends past `inputStallLimit`.
        session.now = { 1000 }
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        let sends = { daemon.recorded.filter { $0["cmd"] as? String == "send" }.count }
        session.send(Data("ls\r".utf8))
        try await waitUntil { sends() == 1 }
        session.send(Data("pwd".utf8))
        try await waitUntil { sends() == 2 }
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { events.contains(.inputNotSent(bytes: 6)) }
        daemon.unansweredSends = false
        session.reconnect()
        try await waitUntil { session.isAttached }
        session.send(Data("x".utf8))
        try await waitUntil { sends() == 3 }
        let last = daemon.recorded.last { $0["cmd"] as? String == "send" }
        #expect(last?["bytes"] as? String == Data("x".utf8).base64EncodedString())
    }

    /// A `send` whose write failed never reached the Mac: it goes again, in
    /// order, before keys typed after it.
    @Test func aSendWhoseWriteFailedIsSentAgainInOrder() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let gate = WriteGate()
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: GatedChannel(try await link.openChannel(service: "daemon", args: [:]), gate: gate))
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        gate.failSends = 1
        session.send(Data("a".utf8))
        try await waitUntil { !session.isAttached }
        session.send(Data("b".utf8))
        session.reconnect()
        try await waitUntil { session.isAttached }
        let typed = { daemon.recorded.filter { $0["cmd"] as? String == "send" }
            .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } }
            .reduce(into: Data()) { $0.append($1) } }
        try await waitUntil { typed() == Data("ab".utf8) }
        #expect(!events.contains { if case .inputNotSent = $0 { true } else { false } })
    }

    /// A failed attach channel is closed, so its other unanswered sends
    /// settle and input after the reattach is not stuck behind them.
    @Test func inputIsNotStuckAfterASendFailsBehindAnUnansweredOne() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredSends = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let gate = WriteGate()
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: GatedChannel(try await link.openChannel(service: "daemon", args: [:]), gate: gate))
        }
        var events: [TerminalSessionEvent] = []
        // A frozen clock: a slow host must not age these sends past `inputStallLimit`.
        session.now = { 1000 }
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        session.send(Data("a".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        gate.failSends = 1
        session.send(Data("b".utf8))
        // "a" was written and is dropped with "b" (it may have been typed).
        try await waitUntil { events.contains(.inputNotSent(bytes: 2)) }
        daemon.unansweredSends = false
        session.reconnect()
        try await waitUntil { session.isAttached }
        session.send(Data("c".utf8))
        try await waitUntil {
            daemon.recorded.last { $0["cmd"] as? String == "send" }?["bytes"] as? String == Data("c".utf8).base64EncodedString()
        }
    }

    /// TUI scroll tail: a `send` with no answer well past the link's round
    /// trip gets three `ping`s behind it on the same channel. Their segments
    /// make the receiver send duplicate ACKs (or later replies), so a lost
    /// last segment of a flick is retransmitted at once instead of after the
    /// 1 s retransmission timeout. The send itself is never repeated.
    @Test func aStalledSendIsFollowedByTailProbes() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredSends = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.tailProbeDelay = .milliseconds(30)
        // A frozen clock: a slow host must not age these sends past `inputStallLimit`.
        session.now = { 1000 }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        session.send(Data("a".utf8))
        let count = { (cmd: String) in daemon.recorded.filter { $0["cmd"] as? String == cmd }.count }
        try await waitUntil { count("ping") >= 3 }
        #expect(count("send") == 1)
    }

    @Test func anAnsweredSendSendsNoTailProbe() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.tailProbeDelay = .seconds(60)
        session.start { _ in }
        try await waitUntil { session.isAttached }
        session.send(Data("a".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        // Answered: the probe armed at the write is gone.
        try await waitUntil { session.inputsInFlight == 0 }
        #expect(!session.tailProbeArmed)
        #expect(!daemon.recorded.contains { $0["cmd"] as? String == "ping" })
    }

    /// TUI scroll tail: a lost reply must not stop input after a few frames
    /// (later sends keep the reverse direction moving, so the loss is
    /// repaired by duplicate ACKs): at least 32 sends may be unanswered.
    @Test func manyUnansweredSendsStillGoOut() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredSends = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.tailProbeDelay = .seconds(60)
        session.now = { 1000 }  // a frozen clock: no send ages past the stall limit
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let sends = { daemon.recorded.filter { $0["cmd"] as? String == "send" }.count }
        let cap = DaemonTerminalSession.maxInputInFlight
        #expect(cap >= 32)
        for n in 1...cap {
            session.send(Data("x".utf8))
            try await waitUntil { sends() == n }
        }
        // The cap still holds: the next one waits for an answer.
        session.send(Data("y".utf8))
        for _ in 0..<10 where sends() <= cap { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sends() == cap)
    }

    /// Review: a stalled link (the oldest unanswered send older than
    /// `inputStallLimit`) holds new keys instead of writing them to arrive
    /// late; they go once the stall clears.
    @Test func aStalledLinkHoldsNewKeys() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredSends = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        var clock: TimeInterval = 1000
        session.now = { clock }
        session.tailProbeDelay = .seconds(60)
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let sends = { daemon.recorded.filter { $0["cmd"] as? String == "send" }.count }
        session.send(Data("a".utf8))
        try await waitUntil { sends() == 1 }
        clock += session.inputStallLimit + 0.1
        session.send(Data("b".utf8))
        for _ in 0..<10 where sends() <= 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sends() == 1)
    }

    /// TUI fast scroll: what one main-queue turn queues (a scroll frame's
    /// wheel reports, which Ghostty writes one by one) is one `send`.
    @Test func oneTurnsInputIsOneSend() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let report = Data("\u{1B}[<64;4;6M".utf8)
        for _ in 0..<5 { session.send(report) }
        let sends = { daemon.recorded.filter { $0["cmd"] as? String == "send" }
            .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } } }
        try await waitUntil { !sends().isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(sends() == [Array(repeating: report, count: 5).reduce(Data(), +)])
    }

    /// The screen shows "Connecting to <Mac>…" until the attach succeeds,
    /// never made-up output.
    @Test func reportsConnectingThenAttached() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.macName = "Studio"
        #expect(session.connectionState == .connecting(mac: "Studio"))
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        #expect(events.first == .connection(.connecting(mac: "Studio")))
        try await waitUntil { events.contains(.connection(.attached)) }
        #expect(session.connectionState == .attached)
    }

    @Test func resizedEventResetsTheMirror() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049h".utf8).base64EncodedString()]))
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 100, "rows": 30,
                                                "replay": Data("fresh".utf8).base64EncodedString()]))
        #expect(events.contains(.alternateScreen(false)))
        #expect(events.contains(.output(Data("\u{1B}c".utf8))))
        #expect(events.last == .output(Data("fresh".utf8)))
    }

    /// termqa V5-4: + → New Terminal made the open tab replay. The Mac sent
    /// `resized` at the grid the phone already mirrors (53x39): a change of
    /// the Mac's cell pixels only (`commit_geometry_for_runtime` sends a
    /// replay to byte mirrors for it). The phone's mirror already holds that
    /// state, so it keeps its screen: no reset, no second copy of the replay.
    @Test func aResizeAtTheSameGridDoesNotResetTheMirror() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 53, "rows": 39,
                                                "data": Data("screen".utf8).base64EncodedString()]))
        events.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 39,
                                                "replay": Data("screen".utf8).base64EncodedString()]))
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("more".utf8).base64EncodedString()]))
        #expect(!events.contains(.output(Data("\u{1B}c".utf8))))
        #expect(events == [.output(Data("more".utf8))])
        // A different grid still resets.
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 42,
                                                "replay": Data("fresh".utf8).base64EncodedString()]))
        #expect(events.contains(.output(Data("\u{1B}c".utf8))))
        #expect(events.last == .output(Data("fresh".utf8)))
        // And then the same grid again does not.
        events.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 42,
                                                "replay": Data("fresh".utf8).base64EncodedString()]))
        #expect(events.isEmpty)
    }

    @Test func resizedEventKeepsATUIWithoutAnOffOnFlicker() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049h".utf8).base64EncodedString()]))
        events.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 24,
                                                "replay": Data("\u{1B}[?1049htop".utf8).base64EncodedString()]))
        #expect(!events.contains(.alternateScreen(false)))
        #expect(!events.contains(.alternateScreen(true)))
        #expect(session.isAlternateScreen)
    }

    @Test func attachFailureIsShownInTheTerminal() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 9) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.lastError != nil }
        #expect(session.lastError?.contains("unknown surface") == true)
        #expect(events.contains { if case .output = $0 { true } else { false } })
    }

    /// The link dropped (background, transport switch, Mac restart): the
    /// channel ends with no `detached` event. The tab must not die; when the
    /// link is back it attaches again, resets the mirror before the replay,
    /// and puts its size back.
    @Test func reattachesAfterTheLinkDrops() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached }
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "resize-surface" } }

        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        #expect(!events.contains(.exited(code: 0)), "a dropped link is not the end of the terminal")

        let before = events.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count == 2 }
        let after = Array(events[before...])
        let reset = after.firstIndex(of: .output(Data("\u{1B}c".utf8)))
        let replay = after.firstIndex(of: .output(Data("hello\r\n$ ".utf8)))
        #expect(reset != nil && replay != nil && reset! < replay!)
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 2)

        // Input typed after the reconnect goes out on the new channel.
        session.send(Data("x".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
    }

    /// termfix-r13 D2 (T-LIFE-17 over `top`): a reattach to a terminal that
    /// is on the alternate screen, and still is, never tells the screen it
    /// left it. Leaving and re-entering switched the page out of TUI mode
    /// with nothing held over it: blank (cursor only) for ~170 ms, then a
    /// half-drawn screen.
    @Test func aReattachToATUIStaysOnTheAlternateScreen() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.replay = "\u{1B}[?1049htop"
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached && session.isAlternateScreen }
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }

        let before = events.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        let after = Array(events[before...])
        #expect(!after.contains(.alternateScreen(false)), "the page left TUI mode during the reattach: \(after)")
        #expect(after.contains(.output(Data("\u{1B}c".utf8))))
        #expect(session.isAlternateScreen)

        // A replay that is back on the primary screen (the program quit
        // during the drop) leaves TUI mode before its rows.
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        daemon.replay = "hello\r\n$ "
        daemon.afterAttach = nil
        let mark = events.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        let primary = Array(events[mark...])
        let off = try #require(primary.firstIndex(of: .alternateScreen(false)))
        let rows = try #require(primary.firstIndex(of: .output(Data("hello\r\n$ ".utf8))))
        #expect(off < rows)
    }

    /// termfix-r13 D4 (T-LIFE-13): the Mac is gone; the session says so
    /// (offline, not "Reattaching…" forever) and attaches again by itself.
    @Test func aDroppedSessionShowsOfflineWhileTheMacIsGone() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        session.macName = "mini"
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        // Attached, the Mac being called offline changes nothing on screen.
        session.setMacOffline(true)
        #expect(session.connectionState == .attached)
        session.setMacOffline(false)

        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        #expect(session.connectionState == .reattaching(mac: "mini"))
        session.setMacOffline(true)
        #expect(session.connectionState == .offline(mac: "mini"))
        #expect(events.last == .connection(.offline(mac: "mini")))
        #expect(TerminalConnectionState.offline(mac: "mini").label == "mini is offline")

        session.setMacOffline(false)
        #expect(events.last == .connection(.reattaching(mac: "mini")))
        let back = events.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        #expect(events[back...].contains(.connection(.attached)))
    }

    /// termfix-r13 D5 (T-INPUT-17): keys typed while the Mac is down are not
    /// queued silently and run minutes later. Keys from a short blip still
    /// go once the terminal is back; older ones are dropped and the screen
    /// is told, so it can say they were not sent.
    @Test func staleInputIsNeverSentAfterAReattach() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var clock: TimeInterval = 1000
        session.now = { clock }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }

        // Typed during the outage, then the Mac is back 15 minutes later.
        session.send(Data("echo STALE\r".utf8))
        clock += 15 * 60
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { events.contains(.inputNotSent(bytes: 11)) }
        #expect(!daemon.recorded.contains { $0["cmd"] as? String == "send" }, "a stale command ran on the Mac")

        // A blip: typed and the terminal back within the bound, sent once.
        await channels.last?.close(code: "link_closed", reason: "blip")
        try await waitUntil { !session.isAttached }
        session.send(Data("x".utf8))
        clock += DaemonTerminalSession.inputHoldLimit / 2
        session.reconnect()
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        let sends = daemon.recorded.filter { $0["cmd"] as? String == "send" }
        #expect(sends.count == 1)
        #expect(sends.first?["bytes"] as? String == Data("x".utf8).base64EncodedString())
    }

    /// r13 review: keys typed over more than the hold limit while detached
    /// are dropped all together, and input is refused until the next attach:
    /// never only the last 2 s of a command (`mp\r` of `ls -la /tmp\r`).
    @Test func noFragmentOfACommandRunsAfterAnOutage() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var clock: TimeInterval = 1000
        session.now = { clock }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }

        session.send(Data("ls -la /t".utf8))
        clock += DaemonTerminalSession.inputHoldLimit + 1
        session.send(Data("mp\r".utf8))
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { events.contains(.inputNotSent(bytes: 12)) }
        #expect(!daemon.recorded.contains { $0["cmd"] as? String == "send" }, "a fragment of the command ran on the Mac")

        // Attached again: typing works.
        session.send(Data("x".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "send" }.first?["bytes"] as? String == Data("x".utf8).base64EncodedString())
    }

    /// termqa D3: right after the Mac's host restarts, a reattach can be refused
    /// ("unknown surface") for a moment. The screen keeps its last frame: no
    /// mirror reset and no error line until an attach succeeds, then the
    /// reset and the replay, in that order.
    @Test func aRefusedReattachKeepsTheLastFrameAndRetries() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "host restarted")
        try await waitUntil { !session.isAttached }

        daemon.failNextAttaches = 2
        let before = events.count
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        let after = Array(events[before...])
        let outputs = after.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }
        // Nothing reached the screen before the good attach: no reset, no "[unknown surface]" line, no stray output.
        #expect(outputs.first == "\u{1B}c")
        #expect(!outputs.contains { $0.contains("unknown surface") || $0.contains("stale") })
        #expect(outputs.contains("hello\r\n$ "))
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 4)
    }

    /// termqa D8: the Mac's own window sets this terminal's grid (39 rows),
    /// so the phone's 42 is overruled. A reattach attaches at the Mac's size
    /// and does not ask for 42 again: the PTY is not resized away and back
    /// (each resize made Codex redraw its whole transcript over the link).
    @Test func aReattachKeepsAnOverruledSize() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        session.start { _ in }
        session.resize(columns: 53, rows: 42)
        try await waitUntil { session.isAttached }
        let first = try #require(daemon.recorded.first { $0["cmd"] as? String == "attach-surface" })
        #expect(first["rows"] as? Int == 42)
        // The Mac keeps 39 rows.
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 39,
                                                "replay": Data("x".utf8).base64EncodedString()]))
        await channels.last?.close(code: "link_closed", reason: "background")
        try await waitUntil { !session.isAttached }
        let resizesBefore = daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        let second = try #require(daemon.recorded.last { $0["cmd"] as? String == "attach-surface" })
        #expect(second["cols"] as? Int == 53)
        #expect(second["rows"] as? Int == 39)
        session.send(Data("x".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count == resizesBefore)
        // A new phone grid asks again.
        session.resize(columns: 53, rows: 40)
        try await waitUntil { daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count == resizesBefore + 1 }
    }

    /// A Mac that keeps a grid wider than the phone's (it was active last) is
    /// never claimed as the phone's own size: the phone renders into its own
    /// grid, so a reattach at the Mac's 113 columns told the daemon the phone
    /// shows 113 and kept the PTY there: a Claude Code session overprinted and
    /// cut every row on the phone (2026-10-23). The reattach asks for the
    /// phone's own grid again.
    @Test func aReattachNeverClaimsAWiderMacGrid() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        session.start { _ in }
        session.resize(columns: 53, rows: 42)
        try await waitUntil { session.isAttached }
        // The Mac keeps its own 113x84.
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 113, "rows": 84,
                                                "replay": Data("x".utf8).base64EncodedString()]))
        await channels.last?.close(code: "link_closed", reason: "background")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil { session.isAttached }
        let second = try #require(daemon.recorded.last { $0["cmd"] as? String == "attach-surface" })
        #expect(second["cols"] as? Int == 53)
        #expect(second["rows"] as? Int == 42)
    }

    /// The terminal channel says it is a phone before it attaches, so the
    /// Mac's daemon holds the grid when the phone's link drops (termqa V2-5:
    /// no resize away and back, so Codex keeps its scrollback).
    @Test func theTerminalChannelSaysItIsAPhoneBeforeAttaching() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(
            surface: 7,
            clientInfo: ["name": "Test iPhone", "kind": "ios", "device_kind": "iphone", "device_id": "d1"]
        ) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        var attached = false
        session.start { if $0 == .connection(.attached) { attached = true } }
        try await waitUntil { attached }
        let order = daemon.recorded.compactMap { $0["cmd"] as? String }
        let info = try #require(daemon.recorded.first { $0["cmd"] as? String == "set-client-info" })
        #expect(info["device_kind"] as? String == "iphone")
        #expect(order.firstIndex(of: "set-client-info")! < order.firstIndex(of: "attach-surface")!)
    }

    @Test func detachedEventEndsTheTerminal() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "detached", "surface": 7, "reason": "closed"]))
        #expect(events.contains(.exited(code: 0)))
    }

    private func waitUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

/// Makes the next `failSends` writes of `send` requests fail, as a channel
/// whose write died; other writes pass.
final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = 0
    var failSends: Int {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func shouldFail(_ data: Data) -> Bool {
        guard String(decoding: data, as: UTF8.self).contains("\"cmd\":\"send\"") else { return false }
        return lock.withLock {
            guard failing > 0 else { return false }
            failing -= 1
            return true
        }
    }
}

final class GatedChannel: LinkChannel, @unchecked Sendable {
    private let inner: any LinkChannel
    private let gate: WriteGate
    init(_ inner: any LinkChannel, gate: WriteGate) {
        self.inner = inner
        self.gate = gate
    }
    var id: UInt32 { inner.id }
    func send(_ data: Data) async throws {
        if gate.shouldFail(data) {
            await inner.close(code: "link_closed", reason: "write failed")
            throw LinkError(code: "link_closed", message: "write failed")
        }
        try await inner.send(data)
    }
    func receive() async throws -> Data? { try await inner.receive() }
    func close(code: String, reason: String) async { await inner.close(code: code, reason: reason) }
}

final class ChannelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [any LinkChannel] = []
    func append(_ channel: any LinkChannel) { lock.withLock { channels.append(channel) } }
    var last: (any LinkChannel)? { lock.withLock { channels.last } }
}

/// Verifier round 3: every reattach logged `attach surface 14: unknown surface
/// 14` and retried it six times: the session of a tab closed earlier (its
/// host kept for the card) was attached again on every new link.
@Suite struct ReattachSurfacesTests {
    /// After the Mac's daemon restarted, the session's surface is gone and its
    /// host id changed; its public id (`terminal_resource_id`) still matches.
    @Test func aRenumberedTerminalStillReattachesByItsPublicID() throws {
        let tab: [String: Any] = ["surface": 269, "kind": "pty", "title": "zsh", "terminal_id": "9a3aaba09e1e4e20b5cb5f9f8f9bc2dc",
                                  "terminal_resource_id": "term_cfa558e1dfd01470a3ed86f97ad61d13"]
        let reply = try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["workspaces": [
            ["id": 1, "key": "ws1", "name": "w", "screens": [["active": true, "active_pane": 1, "panes": [["id": 1, "active_tab": 0, "tabs": [tab]]]]]],
        ]]])
        let tree = try DaemonTree(reply: reply, macID: "m")
        #expect(DaemonTerminalSession.shouldReattach(surface: 25, terminalID: "term_cfa558e1dfd01470a3ed86f97ad61d13", tree: tree))
        #expect(!DaemonTerminalSession.shouldReattach(surface: 25, terminalID: "term_other", tree: tree))
        #expect(DaemonTerminalSession.shouldReattach(surface: 269, terminalID: nil, tree: tree))
    }

    @Test func aClosedTabsSurfaceIsNotAttachedAgain() {
        #expect(DaemonTerminalSession.surfacesToReattach([14, 16, 17], tree: [16, 17]) == [16, 17])
    }

    @Test func beforeTheTreeIsKnownEverySessionReattaches() {
        #expect(DaemonTerminalSession.surfacesToReattach([14, 16], tree: nil) == [14, 16])
    }
}

/// transport-verify-20261019.md defect 2: after the Mac's daemon restarts it
/// numbers its surfaces again, so the phone's open terminal stayed
/// "Reattaching…" and printed `[unknown surface 15]`. A reattach finds the
/// terminal by its durable id (`resolve-terminal`), and a terminal the Mac no
/// longer has ends with a clear line instead of waiting forever.
@MainActor @Suite struct TerminalRenumberTests {
    private func waitUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    func session(_ daemon: FakeTerminalDaemon, _ channels: ChannelLog) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, terminalID: "term_a") {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        session.reattachBackoff = [0.02, 0.02, 0.02]
        return session
    }

    @Test func aReattachFollowsTheTerminalToItsNewSurface() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "Mac app restarted")
        try await waitUntil { !session.isAttached }

        // The daemon came back and put the terminal on surface 15.
        daemon.liveSurface = 15
        daemon.terminals = ["term_a": 15]
        let before = events.count
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        #expect(session.surface == 15)
        #expect(daemon.recorded.last { $0["cmd"] as? String == "attach-surface" }?["surface"] as? Int == 15)
        let after = events[before...].compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }
        #expect(!after.contains { $0.contains("unknown surface") })
        #expect(after.contains("hello\r\n$ "), "the new surface's replay shows")
        session.send(Data("x".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        #expect(daemon.recorded.last { $0["cmd"] as? String == "send" }?["surface"] as? Int == 15)
    }

    @Test func aTerminalTheMacNoLongerHasEndsWithAClearLine() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "Mac app restarted")
        try await waitUntil { !session.isAttached }

        daemon.liveSurface = 15
        daemon.terminals = [:]
        session.reconnect()
        try await waitUntil(attempts: 400) { events.contains(.exited(code: 0)) }
        let text = events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(text.contains("no longer open on the Mac"))
        #expect(session.connectionState != .reattaching(mac: nil), "never stuck reattaching")
        // Never attached to whatever the old number names now.
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 1)
    }

    /// PR #22555 review: a terminal whose shell exited during the outage
    /// says so at once; it never waits "Reattaching…" and never offers a futile
    /// "Type to try again".
    @Test func aTerminalThatExitedWhileAwaySaysSoAtOnce() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }

        daemon.exited = ["term_a"]
        session.reconnect()
        try await waitUntil { events.contains(.exited(code: 0)) }
        let text = events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(text.contains("process exited"))
        #expect(!text.contains("Type to try again"))
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "resolve-terminal" }.count == 1, "no retry round")
    }

    /// Review finding 1: a daemon still adopting its terminals answers a null
    /// surface for a moment; the reattach waits and attaches, never ends.
    @Test func aTerminalNotOnASurfaceYetIsWaitedFor() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "Mac app restarted")
        try await waitUntil { !session.isAttached }
        daemon.liveSurface = 15
        daemon.restoring = 2
        daemon.terminals = ["term_a": 15]
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        #expect(session.surface == 15)
        #expect(!events.contains(.exited(code: 0)))
    }

    /// Live check: right after a Mac app restart the daemon answered
    /// terminal_not_found once for a terminal that was there; it is retried.
    @Test func aTerminalMissingForAMomentIsRetried() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "Mac app restarted")
        try await waitUntil { !session.isAttached }
        daemon.missing = 1
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        #expect(!events.contains(.exited(code: 0)))
    }

    @Test func aDaemonWithoutResolveStillReattachesByNumber() async throws {
        let daemon = FakeTerminalDaemon()
        let channels = ChannelLog()
        let session = session(daemon, channels)
        session.start { _ in }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "background")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        #expect(session.surface == 7)
    }
}
