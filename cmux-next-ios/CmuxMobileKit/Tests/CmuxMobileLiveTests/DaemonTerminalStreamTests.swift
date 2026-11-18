import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-14: "surely we don't need to stream the f***ing thing". A
/// terminal page off screen past its grace (`TerminalStreamGate`) tells its
/// session to stop streaming: the attach channel closes, so output on the Mac
/// with nobody watching costs the phone 0 bytes and reaches no screen; shown
/// again, one attach replays the Mac's screen as it is now.
@MainActor @Suite struct DaemonTerminalStreamTests {
    @Test func aHiddenTerminalPastItsGraceReceivesNoOutputAndShowsTheMacScreenWhenShown() async throws {
        let mac = StreamingMac()
        mac.daemon.afterAttach = nil
        mac.daemon.initialSize = true
        mac.daemon.replay = "row 1\r\n$ "
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: mac.openChannel())
        }
        defer { session.stop() }
        var outputs: [String] = []
        var connections: [TerminalConnectionState] = []
        session.start { event in
            switch event {
            case .output(let data): outputs.append(String(decoding: data, as: UTF8.self))
            case .connection(let state): connections.append(state)
            default: break
            }
        }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached }
        mac.output("live 1\r\n")
        try await waitUntil { outputs.contains("live 1\r\n") }
        #expect(outputs.contains("live 1\r\n"), "a shown terminal streams")

        // The page left the screen: its size is released at once (1 s in the
        // app), its stream past the grace (3 s in the app).
        session.setClaimsSize(false)
        try await waitUntil { mac.commands("release-surface-size").count == 1 }
        session.setStreaming(false)
        try await waitUntil { mac.attachedChannels == 0 }
        #expect(mac.attachedChannels == 0, "a hidden terminal past its grace kept its attach channel open")

        let shownBefore = outputs.count
        let bytesBefore = mac.bytesToPhone
        let connectionsBefore = connections.count
        for row in 2...200 { mac.output("burst \(row)\r\n") }
        try await settle()
        #expect(mac.bytesToPhone == bytesBefore, "output with nobody watching cost the phone \(mac.bytesToPhone - bytesBefore) bytes")
        #expect(outputs.count == shownBefore, "a hidden terminal's page received \(outputs.count - shownBefore) output chunks")
        // The page shows its cache: no "Reattaching…", no "Connecting…".
        #expect(connections.count == connectionsBefore)
        #expect(session.connectionState == .attached)
        // A new link while hidden does not attach it either.
        session.reconnect()
        try await settle()
        #expect(mac.commands("attach-surface").count == 1)

        // Shown again: one attach, at the phone's size, whose replay is the
        // Mac's screen now, after a mirror reset.
        mac.daemon.replay = "burst 200\r\n$ "
        session.setClaimsSize(true)
        session.setStreaming(true)
        try await waitUntil { session.isAttached && outputs.contains("burst 200\r\n$ ") }
        #expect(mac.commands("attach-surface").count == 2)
        let reattach = try #require(mac.commands("attach-surface").last)
        #expect(reattach["cols"] as? Int == 54)
        #expect(reattach["rows"] as? Int == 42)
        let resync = Array(outputs[shownBefore...])
        let reset = String(decoding: TerminalReclaimHold.reset, as: UTF8.self)
        #expect(resync.first == reset, "the resync starts with a mirror reset: \(resync)")
        #expect(resync.contains("burst 200\r\n$ "), "the resync shows the Mac's screen now: \(resync)")
        #expect(!resync.contains { $0.hasPrefix("burst 2\r\n") }, "the hidden output was streamed after all")
        #expect(connections.dropFirst(connectionsBefore).allSatisfy { $0 == .attached }, "showing the page said it was reattaching")

        // Live again.
        mac.output("live 2\r\n")
        try await waitUntil { outputs.contains("live 2\r\n") }
        #expect(outputs.contains("live 2\r\n"))
    }

    @Test func aTerminalHiddenBeforeItStartsAttachesOnlyWhenShown() async throws {
        let mac = StreamingMac()
        mac.daemon.afterAttach = nil
        let session = DaemonTerminalSession(surface: 7) { DaemonClient(channel: mac.openChannel()) }
        defer { session.stop() }
        session.setStreaming(false)
        session.start { _ in }
        try await settle()
        #expect(mac.commands("attach-surface").isEmpty, "a page built off screen attached")
        session.setStreaming(true)
        try await waitUntil { session.isAttached }
        #expect(mac.commands("attach-surface").count == 1)
    }

    @Test func hiddenWhileItsAttachIsOutTheTerminalNeverTakesTheScreen() async throws {
        let mac = StreamingMac()
        mac.daemon.afterAttach = nil
        let session = DaemonTerminalSession(surface: 7) { DaemonClient(channel: mac.openChannel()) }
        defer { session.stop() }
        session.start { _ in }
        session.setStreaming(false)
        try await settle()
        #expect(!session.isAttached)
        #expect(mac.attachedChannels == 0)
        session.setStreaming(true)
        try await waitUntil { session.isAttached }
        #expect(mac.attachedChannels == 1)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A Mac terminal behind the phone's `daemon` channels: requests are answered
/// by a ``FakeTerminalDaemon``, and its output goes to every open channel
/// attached to it, counting the bytes that reach the phone.
final class StreamingMac: @unchecked Sendable {
    let daemon = FakeTerminalDaemon()
    private let lock = NSLock()
    private var channels: [StreamingMacChannel] = []
    private var nextID: UInt32 = 1
    private var sent = 0

    /// Output bytes sent to the phone so far.
    var bytesToPhone: Int { lock.withLock { sent } }
    /// Open channels with an attach.
    var attachedChannels: Int { lock.withLock { channels.filter(\.isAttached).count } }

    func commands(_ cmd: String) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == cmd }
    }

    func openChannel() -> StreamingMacChannel {
        lock.withLock {
            defer { nextID += 2 }
            let channel = StreamingMacChannel(id: nextID, mac: self)
            channels.append(channel)
            return channel
        }
    }

    /// The terminal wrote `text`: every attached channel gets it.
    func output(_ text: String) {
        let line = FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data(text.utf8).base64EncodedString()])
        let attached = lock.withLock { channels.filter(\.isAttached) }
        for channel in attached where channel.push(line) {
            lock.withLock { sent += line.count }
        }
    }

    fileprivate func closed(_ channel: StreamingMacChannel) {
        lock.withLock { channels.removeAll { $0 === channel } }
    }
}

final class StreamingMacChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32
    private weak var mac: StreamingMac?
    private let lock = NSLock()
    private let inbox: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.AsyncIterator
    private var attached = false
    private var open = true

    fileprivate init(id: UInt32, mac: StreamingMac) {
        self.id = id
        self.mac = mac
        (inbox, continuation) = AsyncStream.makeStream()
        iterator = inbox.makeAsyncIterator()
    }

    var isAttached: Bool { lock.withLock { attached && open } }

    func send(_ data: Data) async throws {
        guard let mac, lock.withLock({ open }) else { throw LinkError(code: "closed", message: "channel closed") }
        let replies = mac.daemon.respond("daemon", data)
        if String(decoding: data, as: UTF8.self).contains("\"attach-surface\""),
           replies.contains(where: { String(decoding: $0, as: UTF8.self).contains("\"ok\":true") }) {
            lock.withLock { attached = true }
        }
        for reply in replies { continuation.yield(reply) }
    }

    /// Delivers `line` if the channel is open.
    fileprivate func push(_ line: Data) -> Bool {
        guard lock.withLock({ open }) else { return false }
        continuation.yield(line)
        return true
    }

    func receive() async throws -> Data? {
        await iterator.next()
    }

    func close(code: String, reason: String) async {
        lock.withLock { open = false }
        continuation.finish()
        mac?.closed(self)
    }
}
