import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Attach-stream decoding off the main actor, batched delivery and
/// backpressure (verify/terminal-flood.md).
@Suite struct DaemonTerminalEventParserTests {
    private func line(_ object: [String: Any]) -> Data { FakeTerminalDaemon.line(object) }

    @Test func decodesOutputAndFollowsTheAlternateScreen() {
        var parser = DaemonTerminalEventParser(surface: 7)
        #expect(parser.parse(line(["event": "output", "surface": 7, "data": Data("hi".utf8).base64EncodedString()])) == [.output(Data("hi".utf8))])
        // Split across two lines.
        #expect(parser.parse(line(["event": "output", "surface": 7, "data": Data("\u{1B}[?10".utf8).base64EncodedString()])) == [.output(Data("\u{1B}[?10".utf8))])
        #expect(parser.parse(line(["event": "output", "surface": 7, "data": Data("49hTUI".utf8).base64EncodedString()]))
                == [.output(Data("49hTUI".utf8)), .alternateScreen(true)])
        #expect(parser.parse(line(["event": "output", "surface": 8, "data": Data("other".utf8).base64EncodedString()])).isEmpty)
        #expect(parser.parse(Data("not json".utf8)).isEmpty)
    }

    /// R2-1: a TUI still on screen after a resize is not reported leaving and
    /// re-entering the alternate screen (that resized the PTY back and forth).
    @Test func resizedKeepsATUIOnTheAlternateScreen() {
        var parser = DaemonTerminalEventParser(surface: 7)
        _ = parser.parse(line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049h".utf8).base64EncodedString()]))
        let replay = Data("\u{1B}[?1049htop".utf8)
        let events = parser.parse(line(["event": "resized", "surface": 7, "rows": 24, "replay": replay.base64EncodedString()]))
        #expect(events == [.rows(24), .resetMirror(alternate: true), .output(replay)])
        // Quitting it later is reported once.
        #expect(parser.parse(line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049l".utf8).base64EncodedString()]))
                == [.output(Data("\u{1B}[?1049l".utf8)), .alternateScreen(false)])
    }

    @Test func resizedResetsTheMirrorAndTheDetector() {
        var parser = DaemonTerminalEventParser(surface: 7)
        _ = parser.parse(line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049h".utf8).base64EncodedString()]))
        let events = parser.parse(line(["event": "resized", "surface": 7, "rows": 30, "replay": Data("fresh".utf8).base64EncodedString()]))
        #expect(events == [.rows(30), .resetMirror(alternate: false), .output(Data("fresh".utf8))])
        // The detector starts over: leaving the alternate screen is not reported twice.
        #expect(parser.parse(line(["event": "detached", "surface": 7, "reason": "closed"])) == [.detached(reason: "closed")])
    }
}

@Suite struct DaemonTerminalInboxTests {
    /// Main-queue hops are recorded instead of run, to count them.
    final class Hops: @unchecked Sendable {
        let lock = NSLock()
        var pending: [@Sendable () -> Void] = []
        var count = 0
        func schedule(_ work: @escaping @Sendable () -> Void) {
            lock.withLock { pending.append(work); count += 1 }
        }
        func runAll() {
            let work = lock.withLock { () -> [@Sendable () -> Void] in defer { pending.removeAll() }; return pending }
            for item in work { item() }
        }
    }

    final class Delivered: @unchecked Sendable {
        let lock = NSLock()
        var batches: [[DaemonTerminalInbound]] = []
        func add(_ batch: [DaemonTerminalInbound]) { lock.withLock { batches.append(batch) } }
    }

    @Test func aFloodOfLinesIsOneMainHopPerBatch() async {
        let hops = Hops()
        let delivered = Delivered()
        let inbox = DaemonTerminalInbox(schedule: { hops.schedule($0) }, deliver: { delivered.add($0) })
        for index in 0..<1000 {
            await inbox.push([.output(Data("line \(index)\n".utf8))])
        }
        #expect(hops.count == 1)
        hops.runAll()
        #expect(delivered.batches.count == 1)
        #expect(delivered.batches[0].count == 1000)
        #expect(delivered.batches[0].first == .output(Data("line 0\n".utf8)))
        await inbox.push([.output(Data("next".utf8))])
        #expect(hops.count == 2)
    }

    @Test func theReaderWaitsWhilePausedOrBehind() async throws {
        let hops = Hops()
        let delivered = Delivered()
        let inbox = DaemonTerminalInbox(schedule: { hops.schedule($0) }, deliver: { delivered.add($0) })
        inbox.setPaused(true)
        let done = Flag()
        let reader = Task {
            await inbox.push([.output(Data("x".utf8))])
            done.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!done.value, "a paused screen holds the reader back")
        inbox.setPaused(false)
        _ = await reader.value
        #expect(done.value)

        // Over the high water mark the next push waits for the main actor to drain.
        await inbox.push([.output(Data(count: DaemonTerminalInbox.highWater))])
        let second = Flag()
        let behind = Task {
            await inbox.push([.output(Data("y".utf8))])
            second.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!second.value)
        hops.runAll()
        _ = await behind.value
        #expect(second.value)
        // Closing frees a waiting reader for good.
        inbox.setPaused(true)
        let third = Task { await inbox.push([.output(Data("z".utf8))]) }
        inbox.close()
        _ = await third.value
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool { lock.withLock { on } }
        func set() { lock.withLock { on = true } }
    }
}

/// Files and Links: the Mac refuses a read by closing the channel; that is
/// an explanation on the phone, not an empty file.
@Suite struct LinkFileRefusalTests {
    final class RefusingChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        let refusal: LinkError?
        let data: [Data]
        private var index = 0
        init(refusal: LinkError?, data: [Data] = []) {
            self.refusal = refusal
            self.data = refusal == nil ? [Data("{\"size\":\(data.reduce(0) { $0 + $1.count })}".utf8)] + data : data
        }
        func send(_ data: Data) async throws {}
        func receive() async throws -> Data? {
            defer { index += 1 }
            return index < data.count ? data[index] : nil
        }
        func close(code: String, reason: String) async {}
        var closedBy: LinkError? { index > data.count ? (refusal ?? LinkError(code: "eof", message: "")) : nil }
    }

    final class OneChannelLink: MacLink, @unchecked Sendable {
        let channel: RefusingChannel
        init(_ channel: RefusingChannel) { self.channel = channel }
        var transport: TransportKind { .webRTC }
        var states: AsyncStream<LinkState> { AsyncStream { $0.finish() } }
        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel { channel }
        func ping() async throws -> UInt32 { 0 }
        func close() async {}
    }

    @Test func aRefusedReadExplainsWhy() async {
        let link = OneChannelLink(RefusingChannel(refusal: LinkError(code: "forbidden", message: "path is outside the workspace roots")))
        let source = LinkFileArtifactSource(macName: "Studio", baseDirectory: "/Users/me") { link }
        do {
            _ = try await source.load(TerminalArtifact(reference: "/tmp/sample.md", kind: .markdown))
            Issue.record("a refused read must not load")
        } catch let error as ArtifactUnavailable {
            #expect(error.message == "sample.md is outside the folders Studio shares with this phone. "
                + "Open a workspace in that folder on the Mac, or add it in Settings › General › Chats › Chat Folders.")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func aMacSharingNoFoldersSaysSo() async {
        let link = OneChannelLink(RefusingChannel(refusal: LinkError(code: "forbidden", message: "no workspace roots are shared")))
        let source = LinkFileArtifactSource(macName: "Studio", baseDirectory: "/Users/me") { link }
        do {
            _ = try await source.load(TerminalArtifact(reference: "notes.md", kind: .markdown))
            Issue.record("a refused read must not load")
        } catch let error as ArtifactUnavailable {
            #expect(error.message == "Studio isn't sharing folders with this phone. "
                + "Open a workspace in that folder on the Mac, or add it in Settings › General › Chats › Chat Folders.")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func aRealFileLoadsAndAnEmptyOneSaysSo() async throws {
        let text = OneChannelLink(RefusingChannel(refusal: nil, data: [Data("# Title\n\nhello ".utf8), Data("from the Mac\n".utf8)]))
        let loaded = try await LinkFileArtifactSource(macName: "Studio", baseDirectory: "/Users/me") { text }
            .load(TerminalArtifact(reference: "notes.md", kind: .markdown))
        guard case .text(let body) = loaded else { Issue.record("not text: \(loaded)"); return }
        #expect(body == "# Title\n\nhello from the Mac\n")

        let empty = OneChannelLink(RefusingChannel(refusal: nil))
        let none = try await LinkFileArtifactSource(macName: "Studio", baseDirectory: "/Users/me") { empty }
            .load(TerminalArtifact(reference: "empty.md", kind: .markdown))
        guard case .binary(let description) = none else { Issue.record("an empty file must not render as a blank page"); return }
        #expect(description.hasPrefix("Empty file"))
    }
}
