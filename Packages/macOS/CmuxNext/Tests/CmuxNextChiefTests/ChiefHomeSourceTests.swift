import CmuxHomeCore
@testable import CmuxNextChief
import Foundation
import Testing

/// A Worker in memory: dense seqs, sends idempotent by client id, a poll that
/// answers at once (empty when nothing is new).
actor FakeChiefTransport: ChiefTransport {
    var log: [ChiefWireMessage] = []
    var failNext = false

    func append(_ kind: ChiefWireMessage.Kind, _ author: String, _ text: String, id: String? = nil) -> ChiefWireMessage {
        let seq = UInt64(log.count + 1)
        let m = ChiefWireMessage(seq: seq, id: id ?? "\(kind.rawValue):\(seq)", kind: kind, author: author, text: text, at: Double(seq) * 1000)
        log.append(m)
        return m
    }

    func failOnce() { failNext = true }

    private func check() throws {
        if failNext { failNext = false; throw ChiefTransportError.unreachable }
    }

    func messages(after: UInt64, wait: Int) async throws -> [ChiefWireMessage] {
        try check()
        return log.filter { $0.seq > after }
    }

    func tail(_ count: Int) async throws -> [ChiefWireMessage] {
        try check()
        return Array(log.suffix(count))
    }

    func page(before: UInt64, limit: Int) async throws -> [ChiefWireMessage] {
        try check()
        return Array(log.filter { $0.seq < before }.suffix(limit))
    }

    func send(clientID: String, text: String, from: String) async throws -> ChiefWireMessage {
        try check()
        if let known = log.first(where: { $0.id == "human:\(clientID)" }) { return known }
        return append(.human, from, text, id: "human:\(clientID)")
    }
}

struct ChiefHomeSourceTests {
    private func source(_ transport: FakeChiefTransport) -> ChiefHomeSource {
        ChiefHomeSource(transport: transport, chiefID: "t", meName: "Lawrence", now: Date(timeIntervalSince1970: 0))
    }

    @Test func mapsAuthorsAndKeepsTheClientIDOfMyMessages() async throws {
        let transport = FakeChiefTransport()
        _ = await transport.append(.human, "Lawrence", "hi", id: "human:cmk_abc")
        _ = await transport.append(.chief, "Chief", "Starting a worker.")
        _ = await transport.append(.worker, "fix", "done")
        _ = await transport.append(.error, "Chief", "This turn failed: x")
        let s = source(transport)
        let page = try await s.snapshot(of: s.conversation, tail: 10)
        #expect(page.messages.map(\.seq) == [1, 2, 3, 4])
        #expect(page.messages[0].author == s.me.id)
        #expect(page.messages[0].clientMessageID == IdempotencyKey("cmk_abc"))
        #expect(page.messages[1].author == s.chief.id)
        #expect(page.messages[2].author == ParticipantID("agent_worker_fix"))
        #expect(page.messages[3].plainText == "⚠︎ This turn failed: x")
        #expect(page.conversation.rev == 4 && page.conversation.lastSeq == 4)
        #expect(page.conversation.kind(me: s.me.id) == .group)
        #expect(page.conversation.participants.map(\.displayName) == ["Lawrence", "Chief", "fix"])
    }

    @Test func sendIsIdempotentByKeyAndAnswersWithTheMessageSeq() async throws {
        let transport = FakeChiefTransport()
        let s = source(transport)
        let intent = HomeIntent(key: IdempotencyKey("cmk_one"), op: .sendMessage(conversation: s.conversation, parts: [.text("hello")]))
        #expect(try await s.submit(intent).rev == 1)
        #expect(try await s.submit(intent).rev == 1)
        #expect(await transport.log.count == 1)
    }

    @Test func unreachableBecomesARetryableRejection() async throws {
        let transport = FakeChiefTransport()
        await transport.failOnce()
        let s = source(transport)
        let intent = HomeIntent(op: .sendMessage(conversation: s.conversation, parts: [.text("x")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await s.submit(intent) }
    }

    @Test func refusesOpsTheExperimentDoesNotHave() async throws {
        let s = source(FakeChiefTransport())
        await #expect(throws: HomeRejection.self) { try await s.submit(HomeIntent(op: .createChief(name: "x"))) }
    }

    @Test func eventsGoOnlineThenPublishTheInboxThenMessagesWithDenseRevisions() async throws {
        let transport = FakeChiefTransport()
        _ = await transport.append(.human, "Lawrence", "hi")
        let s = source(transport)
        var it = await s.events().makeAsyncIterator()
        #expect(await it.next() == .connection(.connecting))
        #expect(await it.next() == .connection(.online))
        guard case .inbox(let inbox) = await it.next() else { Issue.record("no inbox"); return }
        #expect(inbox.conversations.first?.lastSeq == 1)
        _ = await transport.append(.chief, "Chief", "hello")
        _ = await transport.append(.worker, "w1", "report")
        var revs: [Revision] = []
        var sawWorkerJoin = false
        while revs.count < 2, let event = await it.next() {
            switch event {
            case .message(let m, let rev): revs.append(rev); #expect(m.seq == rev)
            case .conversationChanged(let summary, .inbox, _): sawWorkerJoin = summary.participants.contains { $0.displayName == "w1" }
            default: break
            }
        }
        #expect(revs == [2, 3])
        #expect(sawWorkerJoin)
    }

    @Test func configLoadsFromItsFileAndIsAbsentWithoutOne() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "chief.json")
        #expect(ChiefExperimentConfig.load(from: file) == nil)
        try Data(#"{"url":"https://x.example","token":"t","chief":"c","me":"M"}"#.utf8).write(to: file)
        #expect(ChiefExperimentConfig.load(from: file) == ChiefExperimentConfig(url: URL(string: "https://x.example")!, token: "t", chief: "c", me: "M"))
    }
}
