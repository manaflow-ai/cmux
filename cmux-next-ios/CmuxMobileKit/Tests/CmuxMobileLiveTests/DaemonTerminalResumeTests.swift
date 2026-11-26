import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A daemon with cmux-tui's `terminal-resume-v1`: its byte stream carries `offset` and
/// `generation`, and an attach that names them gets only the bytes after that offset
/// (`resume: "exact"`) or, when it has them no more, the whole replay (`resume: "gap"`).
private final class ResumingDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String: Any]] = []
    /// `identify` lists `terminal-resume-v1` and `terminal-resume-bounded-v1`.
    var advertises = true
    /// A resume from the current position is answered exactly (the bytes are in the ring).
    var exact = true
    static let generation = "00ab.0"
    static let replay = "hello\r\n"
    static let tail = "$ "
    static let missed = "ls output\r\n$ "

    var recorded: [[String: Any]] { lock.withLock { commands } }
    var attaches: [[String: Any]] { recorded.filter { $0["cmd"] as? String == "attach-surface" } }

    func respond(_ service: String, _ data: Data) -> [Data] {
        data.split(separator: 0x0A).flatMap { respondLine(service, Data($0)) }
    }

    private func respondLine(_ service: String, _ line: Data) -> [Data] {
        guard service == "daemon", let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return [] }
        lock.withLock { commands.append(object) }
        func reply(_ data: [String: Any] = [:]) -> Data { Self.line(["id": id, "ok": true, "data": data]) }
        func event(_ name: String, _ bytes: String, offset: Int, _ extra: [String: Any] = [:]) -> Data {
            var fields: [String: Any] = ["event": name, "surface": 7, "data": Data(bytes.utf8).base64EncodedString()]
            if lock.withLock({ advertises }) {
                fields["offset"] = offset
                fields["generation"] = Self.generation
            }
            return Self.line(fields.merging(extra) { $1 })
        }
        switch cmd {
        case "identify":
            return [reply(["capabilities": lock.withLock { advertises } ? ["terminal-resume-v1", "terminal-resume-bounded-v1"] : []])]
        case "attach-surface":
            let through = Self.replay.utf8.count + Self.tail.utf8.count
            let asked = object["resume_offset"] as? Int
            if let asked, asked == through, object["resume_generation"] as? String == Self.generation, lock.withLock({ exact }) {
                return [event("output", Self.missed, offset: through + Self.missed.utf8.count, ["resume": "exact"]),
                        reply(["resume": "exact", "through": through + Self.missed.utf8.count, "generation": Self.generation])]
            }
            var data: [String: Any] = [:]
            if asked != nil { data = ["resume": "gap", "through": through, "generation": Self.generation] }
            return [event("vt-state", Self.replay, offset: Self.replay.utf8.count, ["cols": 80, "rows": 24]),
                    reply(data),
                    event("output", Self.tail, offset: through)]
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

/// Leo, 2026-11-24, back from dictating in another app: "The like multi-second long reattach
/// where like the entire thing is somehow grayed out". A reattach resumes the byte stream
/// from where the mirror stands instead of resetting it and replaying the screen and history.
@MainActor @Suite struct DaemonTerminalResumeTests {
    @Test func aReattachGetsOnlyTheMissedBytesOnTheSameMirror() async throws {
        let daemon = ResumingDaemon()
        let (session, channels) = session(daemon)
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached && text(events).hasSuffix(ResumingDaemon.tail) }
        let first = try #require(daemon.attaches.first)
        #expect(first["resume_offset"] == nil, "a first attach has nothing to resume")

        await channels.last?.close(code: "link_closed", reason: "app switched away")
        try await waitUntil { !session.isAttached }
        events.removeAll()
        session.reconnect()
        try await waitUntil { session.isAttached && text(events).contains("ls output") }

        let again = try #require(daemon.attaches.last)
        #expect(again["resume_offset"] as? Int == ResumingDaemon.replay.utf8.count + ResumingDaemon.tail.utf8.count)
        #expect(again["resume_generation"] as? String == ResumingDaemon.generation)
        #expect(again["resume_max_bytes"] as? Int == DaemonTerminalSession.minResumeBytes)
        // No reset, no replay: only what the phone missed, after what it holds.
        #expect(text(events) == ResumingDaemon.missed)

        // And the next reattach resumes from after those bytes.
        await channels.last?.close(code: "link_closed", reason: "again")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil { daemon.attaches.count == 3 && session.isAttached }
        let third = try #require(daemon.attaches.last)
        #expect(third["resume_offset"] as? Int == ResumingDaemon.replay.utf8.count + ResumingDaemon.tail.utf8.count + ResumingDaemon.missed.utf8.count)
    }

    @Test func aGapResetsAndReplaysAsBefore() async throws {
        let daemon = ResumingDaemon()
        daemon.exact = false
        let (session, channels) = session(daemon)
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached && text(events).hasSuffix(ResumingDaemon.tail) }
        await channels.last?.close(code: "link_closed", reason: "away too long")
        try await waitUntil { !session.isAttached }
        events.removeAll()
        session.reconnect()
        try await waitUntil { session.isAttached && text(events).hasSuffix(ResumingDaemon.tail) }
        #expect(daemon.attaches.last?["resume_offset"] != nil)
        #expect(text(events) == "\u{1B}c" + ResumingDaemon.replay + ResumingDaemon.tail)
    }

    @Test func aDaemonWithoutResumeIsNeverAskedForIt() async throws {
        let daemon = ResumingDaemon()
        daemon.advertises = false
        let (session, channels) = session(daemon)
        defer { session.stop() }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached && text(events).hasSuffix(ResumingDaemon.tail) }
        await channels.last?.close(code: "link_closed", reason: "dropped")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil { daemon.attaches.count == 2 && session.isAttached }
        #expect(daemon.attaches.allSatisfy { $0["resume_offset"] == nil && $0["resume_generation"] == nil })
    }

    @Test func theClientDeclaresResume() {
        #expect(DaemonTerminalSession.clientCapabilities.contains("terminal-resume-v1"))
        #expect(DaemonTerminalSession.clientCapabilities.contains("terminal-resume-bounded-v1"))
    }

    @Test func theParserFollowsTheStreamPosition() {
        var parser = DaemonTerminalEventParser(surface: 7)
        let stamped = parser.parse(ResumingDaemon.line(["event": "output", "surface": 7, "data": Data("hi".utf8).base64EncodedString(),
                                                        "offset": 42, "generation": "00ab.3"]))
        #expect(stamped == [.output(Data("hi".utf8)), .streamPosition(TerminalStreamPosition(offset: 42, generation: "00ab.3"))])
        // An unstamped line (an older daemon) says nothing about the position.
        let plain = parser.parse(ResumingDaemon.line(["event": "output", "surface": 7, "data": Data("hi".utf8).base64EncodedString()]))
        #expect(plain == [.output(Data("hi".utf8))])
        // A resumed attach on the alternate screen leaves it when its bytes do.
        var resumed = DaemonTerminalEventParser(surface: 7, alternate: true, bytesResume: true)
        let left = resumed.parse(ResumingDaemon.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049l".utf8).base64EncodedString()]))
        #expect(left.contains(.alternateScreen(false)))
    }

    private func session(_ daemon: ResumingDaemon) -> (DaemonTerminalSession, ChannelLog) {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        return (session, channels)
    }

    private func text(_ events: [TerminalSessionEvent]) -> String {
        events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
