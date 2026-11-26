import Foundation
import Testing
@testable import CmuxMobileAgentChat
@testable import CmuxMobileLive
import CmuxMobileTransport

@MainActor
@Suite struct UploadSendDeadlineTests {
    /// One upload channel. Its native counter moves eight times inside a single write. The
    /// saving reply can also stall after the last byte, without any more delivery progress.
    final class Upload: MacLink, LinkChannel, @unchecked Sendable {
        let id: UInt32 = 3
        let transport: TransportKind = .webRTC
        let states = AsyncStream<LinkState> { $0.finish() }
        private let lock = NSLock()
        private let writeStep: Duration
        private let ticks: AsyncStream<Void>?
        private let replies: Bool
        private var bytes: UInt64 = 0
        private var answered = false
        private var opens = 0
        private var closes = 0
        var sentBytes: UInt64? { lock.withLock { bytes } }
        var opened: Int { lock.withLock { opens } }
        var closed: Int { lock.withLock { closes } }

        init(writeStep: Duration = .zero, ticks: AsyncStream<Void>? = nil, replies: Bool = true) {
            self.ticks = ticks
            self.writeStep = writeStep
            self.replies = replies
        }

        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            #expect(service == "upload")
            lock.withLock { opens += 1 }
            return self
        }
        func send(_ data: Data) async throws {
            var steps = ticks?.makeAsyncIterator()
            for part in 1...8 {
                if steps != nil {
                    guard await steps?.next() != nil else { throw CancellationError() }
                } else {
                    try await Task.sleep(for: writeStep) // test: part of a single channel write drained
                }
                lock.withLock { bytes = UInt64(data.count * part / 8) }
            }
        }
        func receive() async throws -> Data? {
            if !replies { try await Task.sleep(for: .seconds(30)) } // test: cancelled by the upload deadline
            return lock.withLock {
                guard !answered else { return nil }
                answered = true
                return Data(#"{"path":"/w/clip.bin"}"#.utf8)
            }
        }
        func close(code: String, reason: String) async { lock.withLock { closes += 1 } }
        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    private let file = AgentAttachment(kind: .file, name: "clip.bin", data: Data(repeating: 0xa5, count: 8192))

    /// Exercise the actual composer, pre-stager, upload and Rust prompt outbox. The optimistic
    /// bubble crosses two 60-second deadlines before the pending channel write has returned.
    #if canImport(CmuxMobileLinkFFI)
    @Test(arguments: [false, true])
    func bubbleSurvivesAdvancingUpload(prestage: Bool) async throws {
        let mac = ChatPromptBlipTests.Mac()
        let (hub, _, _, store) = try await ChatPromptBlipTests().openChat(mac)
        defer { withExtendedLifetime(hub) {} }
        let (ticks, advance) = AsyncStream<Void>.makeStream()
        defer { advance.finish() }
        let wire = Upload(ticks: ticks)
        hub.macLink = wire
        let timer = LinkTestClock()
        defer { timer.stop() }
        store.sendClock = timer
        if prestage { store.composerAttachmentsChanged([file]) }
        store.send(prompt: "look", attachments: [file])
        store.composerAttachmentsChanged([])
        let wait = HeldPromptSlowWriteTests()
        let id = try #require(store.turns.last?.promptID)
        for part in 1...2 {
            advance.yield(())
            await wait.eventually { timer.nextDeadline != nil && wire.sentBytes == UInt64(part * 1024) }
            try #require(wire.sentBytes == UInt64(part * 1024))
            timer.advance(by: .seconds(60))
            await wait.eventually { timer.isSleeping(after: timer.now) || store.turns.last?.localSend == .notSent }
            try #require(timer.isSleeping(after: timer.now))
            try #require(store.turns.last?.localSend == .sending)
        }
        for _ in 3...8 { advance.yield(()) }
        await wait.eventually { mac.prompts.count == 1 }
        #expect(mac.prompts.map(\.promptID) == [id])
        #expect(wire.opened == 1)
    }
    #endif

    @Test func aWrittenPromptWithNoReplyOrJournalEchoStillTimesOut() async throws {
        let mac = ChatPromptBlipTests.Mac(answersPrompts: false)
        let (hub, _, source, store) = try await ChatPromptBlipTests().openChat(mac)
        defer { withExtendedLifetime(hub) {} }
        let timer = LinkTestClock()
        defer { timer.stop() }
        store.sendClock = timer
        store.send(prompt: "still there")
        let id = try #require(store.turns.last?.promptID)
        let wait = HeldPromptSlowWriteTests()
        await wait.eventually {
            mac.prompts.count == 1 && !source.isDeliveringPrompt(id) && timer.nextDeadline != nil
        }
        try #require(mac.prompts.count == 1 && !source.isDeliveringPrompt(id))
        timer.advance(by: .seconds(60))
        await wait.eventually { store.turns.last?.localSend == .notSent }
        #expect(store.turns.last?.localSend == .notSent)
        await hub.bind(nil)
    }

    @Test func aSingleChannelWriteMayKeepDrainingAcrossStallWindows() async throws {
        let wire = Upload(writeStep: .milliseconds(200))
        let path = try await LinkUpload.upload(.data(Data(repeating: 42, count: 8192)), name: "clip.bin",
                                               cwd: "/w", over: wire, stall: .milliseconds(700))
        #expect(path == "/w/clip.bin")
        #expect(wire.sentBytes == 8192)
    }

    @Test func aStalledSaveClosesTheUploadAndMarksTheBubble() async throws {
        let mac = ChatPromptBlipTests.Mac()
        let (hub, _, source, store) = try await ChatPromptBlipTests().openChat(mac)
        defer { withExtendedLifetime(hub) {} }
        let wire = Upload(writeStep: .zero, replies: false)
        hub.macLink = wire
        source.heldPromptWindow = .milliseconds(100)
        store.send(prompt: "look", attachments: [file])
        await HeldPromptSlowWriteTests().eventually { store.turns.last?.localSend == .notSent && wire.closed == 1 }
        #expect(store.turns.last?.localSend == .notSent)
        #expect(wire.closed == 1)
        #expect(store.clientError == nil)
        #expect(mac.prompts.isEmpty)
    }
}
