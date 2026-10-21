@testable import CmuxChief
import CmuxHomeCore
import CryptoKit
import Foundation
import Testing

@Suite struct ChiefConversationOwnerTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    @Test func defaultChiefConversationExists() async throws {
        let owner = try ChiefFixture().owner(.replying(["hi"]))
        let inbox = await owner.inbox()
        let summary = try #require(inbox.conversations.first { $0.id == conversation })
        #expect(summary.kind(me: ChiefConversationOwner.userID) == .chief)
        #expect(summary.participants.contains { $0.isChief && $0.displayName == "Chief" })
        #expect(inbox.me.displayName == "Tester")
        // A row in Home's list, not a lone pinned tile: only the user pins.
        #expect(summary.pinRank == nil)
    }

    @Test func draftUpdatesDoNotInvalidateTheInboxCursor() async throws {
        let owner = try ChiefFixture().owner(.replying(["hi"]))
        let before = await owner.inboxChangeCursor
        let draft = HomeDraftUpdate(
            conversation: conversation,
            participant: ChiefConversationOwner.chiefID,
            turn: IdempotencyKey("turn-1"),
            segment: 0,
            seq: 1,
            isTalk: true,
            text: "hi",
            fresh: true,
            done: false
        )

        await owner.publish(.draft(draft))

        #expect(await owner.inboxChangeCursor == before)
    }

    /// The order Home expects: user message, Chief read receipt, typing on,
    /// drafts, the Chief's message under the draft's key, typing off.
    @Test func sendCommitsUserMessageThenChiefReplies() async throws {
        let brain = FakeBrain.replying(["Hello", " there"])
        let owner = try ChiefFixture().owner(brain)
        let recorder = EventRecorder()
        await recorder.start(owner)
        try await ChiefFixture.send("hi Chief", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 2)
        #expect(messages.map(\.plainText) == ["hi Chief", "Hello there"])
        #expect(messages[0].author == ChiefConversationOwner.userID)
        #expect(messages[1].author == ChiefConversationOwner.chiefID)

        _ = await ChiefFixture.eventually {
            await recorder.events.contains { if case .typing(_, _, on: false) = $0 { return true }; return false }
        }
        let events = await recorder.events
        func index(_ match: (HomeEvent) -> Bool) -> Int { events.firstIndex(where: match) ?? -1 }
        let userPosted = index { if case .message(let m, _) = $0 { return m.author == ChiefConversationOwner.userID }; return false }
        let readReceipt = index {
            if case .conversationChanged(let summary, .conversation, _) = $0 {
                return summary.readCursors[ChiefConversationOwner.chiefID] == messages[0].seq
            }
            return false
        }
        let typingOn = index { if case .typing(_, ChiefConversationOwner.chiefID, on: true) = $0 { return true }; return false }
        let firstDraft = index { if case .draft = $0 { return true }; return false }
        let chiefPosted = index { if case .message(let m, _) = $0 { return m.author == ChiefConversationOwner.chiefID }; return false }
        let typingOff = index { if case .typing(_, ChiefConversationOwner.chiefID, on: false) = $0 { return true }; return false }
        #expect(userPosted >= 0)
        #expect(userPosted < readReceipt)
        #expect(readReceipt < typingOn)
        #expect(typingOn < firstDraft)
        #expect(firstDraft < chiefPosted)
        #expect(chiefPosted < typingOff)

        let drafts = await recorder.drafts()
        #expect(drafts.count == 2)
        #expect(drafts.first?.fresh == true)
        #expect(drafts.first?.text == "Hello")
        #expect(drafts.last?.text == " there")
        #expect(drafts.last?.seq == (drafts.first?.seq ?? 0) + 1)
        #expect(drafts.allSatisfy { $0.turn == messages[1].clientMessageID })

        // Revisions on the conversation stream are dense.
        var revs: [Revision] = []
        for event in events {
            switch event {
            case .message(_, let rev): revs.append(rev)
            case .conversationChanged(_, .conversation, let rev): revs.append(rev)
            default: break
            }
        }
        #expect(revs == Array(revs.first!..<(revs.first! + Revision(revs.count))))

        let requests = await brain.log.requests
        #expect(requests.count == 1)
        #expect(requests.first?.userText == "hi Chief")
        #expect(requests.first?.systemPrompt == "You are Chief.")
        #expect(requests.first?.environment["CHIEF"] == "1")
        #expect(requests.first?.resumeSession == nil)
    }

    @Test func eachTextSegmentIsOneBubble() async throws {
        let owner = try ChiefFixture().owner(.events([
            .textDelta("One"), .textSegmentEnd, .textDelta("Two"), .textSegmentEnd, .finished
        ]))
        try await ChiefFixture.send("go", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 3)
        #expect(messages.map(\.plainText) == ["go", "One", "Two"])
    }

    @Test func toolCallsAreWorkPartsUpdatedInPlace() async throws {
        let owner = try ChiefFixture().owner(.events([
            .textDelta("Looking"), .toolStarted(id: "t1", title: "Read file", detail: "README.md"),
            .toolStarted(id: "t2", title: "Run tests", detail: nil),
            .toolFinished(id: "t1", ok: true, preview: "42 lines"), .toolFinished(id: "t2", ok: false, preview: nil),
            .textDelta("Done"), .textSegmentEnd, .finished
        ]))
        let recorder = EventRecorder()
        await recorder.start(owner)
        try await ChiefFixture.send("check", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 5)
        #expect(messages.map(\.plainText) == ["check", "Looking", "42 lines", "Run tests", "Done"])
        guard case .work(let read) = messages[2].parts.first, case .work(let tests) = messages[3].parts.first else {
            Issue.record("expected work parts")
            return
        }
        #expect(read.session == "t1" && read.title == "Read file" && read.status == .done)
        #expect(tests.status == .failed)
        _ = await ChiefFixture.eventually { await recorder.messages().count >= 7 }
        let updates = await recorder.messages().filter { $0.id == messages[2].id }
        let statuses = updates.compactMap { message -> WorkRef.Status? in
            if case .work(let work) = message.parts.first { return work.status }
            return nil
        }
        #expect(statuses == [.running, .done])
    }

    @Test func failurePostsErrorMessage() async throws {
        let owner = try ChiefFixture().owner(.events([.textDelta("Partial"), .failed("model unavailable")]))
        try await ChiefFixture.send("hi", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 3)
        #expect(messages[1].plainText == "Partial")
        #expect(messages[2].author == ChiefConversationOwner.chiefID)
        #expect(messages[2].plainText.contains("model unavailable"))
    }

    @Test func stopCancelsTheTurn() async throws {
        let brain = FakeBrain { _, continuation in
            continuation.yield(.toolStarted(id: "t1", title: "Long job", detail: nil))
            continuation.yield(.textDelta("partial"))
            // Runs until the stream is terminated (the stop cancels this task).
            try? await Task.sleep(nanoseconds: 120_000_000_000)
        }
        let owner = try ChiefFixture().owner(brain)
        let working = await owner.workingConversations()
        var states = working.makeAsyncIterator()
        let initial = await states.next()
        #expect(initial == [])
        let recorder = EventRecorder()
        await recorder.start(owner)
        try await ChiefFixture.send("do it", to: owner)
        let started = await states.next()
        #expect(started == [conversation])
        #expect(await ChiefFixture.eventually { await !recorder.drafts().isEmpty })
        #expect(await owner.isWorking(conversation))

        #expect(await owner.stopTurn(conversation: conversation))
        #expect(await owner.isWorking(conversation) == false)
        let stopped = await states.next()
        #expect(stopped == [])
        #expect(await brain.log.interrupts == [conversation])
        #expect(await ChiefFixture.eventually { await brain.log.terminations == 1 })
        let messages = try await owner.snapshot(of: conversation, tail: 10).messages
        #expect(messages.dropLast().last?.plainText == "partial")
        if case .work(let work) = messages[1].parts.first { #expect(work.status == .failed) } else { Issue.record("no work part") }
        // A quiet "Stopped" row marks where the reply ends (ChiefConversationOwner+Notices.swift).
        guard case .work(let stoppedRow)? = messages.last?.parts.first, messages.last?.parts.count == 1 else {
            Issue.record("no stopped row"); return
        }
        #expect(stoppedRow.session.hasPrefix(ChiefConversationOwner.stoppedSessionPrefix))
        #expect(stoppedRow.title == "Stopped" && stoppedRow.host == nil && stoppedRow.status == .done)
        #expect(await owner.stopTurn(conversation: conversation) == false)
    }

    @Test func messagesSentWhileWorkingRunAsTheNextTurn() async throws {
        let gate = Gate()
        let brain = FakeBrain { request, continuation in
            if request.userText == "first" { await gate.wait() }
            continuation.yield(.textDelta("re: \(request.userText)"))
            continuation.yield(.textSegmentEnd)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("first", to: owner)
        #expect(await ChiefFixture.eventually { await brain.log.requests.count == 1 })
        try await ChiefFixture.send("second", to: owner)
        // The second message commits at once but waits for the first turn.
        #expect(try await owner.snapshot(of: conversation, tail: 10).messages.map(\.plainText) == ["first", "second"])
        #expect(await brain.log.requests.count == 1)
        await gate.open()
        let messages = try await ChiefFixture.idleMessages(owner, count: 4)
        #expect(messages.map(\.plainText) == ["first", "second", "re: first", "re: second"])
        #expect(await brain.log.requests.map(\.userText) == ["first", "second"])
    }

    @Test func persistsAcrossRelaunchAndResumesSession() async throws {
        let fixture = ChiefFixture()
        let first = try fixture.owner(.replying(["Remembered"], session: "cli-session-1"))
        try await ChiefFixture.send("remember me", to: first)
        _ = try await ChiefFixture.idleMessages(first, count: 2)
        await first.shutdown()

        // A crash mid-write leaves a partial line; loading skips it.
        let file = fixture.home.conversationsDirectory.appendingPathComponent("conv_chief.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"message\":{\"_0\":{\"id\":".utf8))
        try handle.close()

        let brain = FakeBrain.replying(["Again"])
        let second = try fixture.owner(brain)
        let reloaded = try await second.snapshot(of: conversation, tail: 10)
        #expect(reloaded.messages.map(\.plainText) == ["remember me", "Remembered"])
        #expect(reloaded.conversation.lastSeq == 2)
        try await ChiefFixture.send("still there?", to: second)
        let messages = try await ChiefFixture.idleMessages(second, count: 4)
        #expect(messages.map(\.seq) == [1, 2, 3, 4])
        #expect(await brain.log.requests.first?.resumeSession == "cli-session-1")

        await second.shutdown()
        let third = try fixture.owner(.replying([]))
        #expect(try await third.snapshot(of: conversation, tail: 10).messages.map(\.plainText)
            == ["remember me", "Remembered", "still there?", "Again"])
    }

    @Test func sendIsIdempotentByKey() async throws {
        let brain = FakeBrain.replying(["ok"])
        let owner = try ChiefFixture().owner(brain)
        let key = IdempotencyKey("send-once")
        let first = try await ChiefFixture.send("once", to: owner, key: key)
        let again = try await ChiefFixture.send("once", to: owner, key: key)
        #expect(first.replayed == false)
        #expect(again.replayed == true)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        #expect(try await owner.snapshot(of: conversation, tail: 10).messages.filter { $0.clientMessageID == key }.count == 1)
    }

    @Test func createChiefMakesItsOwnConversation() async throws {
        let brain = FakeBrain.replying(["On it"])
        let owner = try ChiefFixture().owner(brain)
        let recorder = EventRecorder()
        await recorder.start(owner)
        let result = try await owner.submit(HomeIntent(op: .createChief(name: "Research")))
        let id = try #require(result.conversation)
        let inbox = await owner.inbox()
        let summary = try #require(inbox.conversations.first(where: { $0.id == id }))
        let researcher = try #require(summary.participants.first(where: { $0.isChief }))
        #expect(researcher.displayName == "Research")
        #expect(researcher.id != ChiefConversationOwner.chiefID)
        // The recorder hears events on its own task: wait for the inbox change.
        #expect(await ChiefFixture.eventually {
            await recorder.events.contains {
                if case .conversationChanged(let changed, .inbox, _) = $0 { return changed.id == id }
                return false
            }
        })
        try await ChiefFixture.send("find papers", to: owner, in: id)
        let messages = try await ChiefFixture.idleMessages(owner, in: id, count: 2)
        #expect(messages.last?.author == researcher.id)
        #expect(await brain.log.requests.first?.conversation == id)
        await #expect(throws: HomeRejection.invalid("invalid_name")) {
            try await owner.submit(HomeIntent(op: .createChief(name: "  ")))
        }
    }

    @Test func reactionsEditsAndRetractions() async throws {
        let owner = try ChiefFixture().owner(.replying(["Sure"]))
        try await ChiefFixture.send("typo", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 2)
        let reply = messages[1]
        try await owner.submit(HomeIntent(op: .addReaction(message: reply.id, conversation: conversation,
                                                           reaction: .tapback(.love), partIndex: 0)))
        var page = try await owner.snapshot(of: conversation, tail: 10)
        #expect(page.messages[1].reactions == [Reaction(author: ChiefConversationOwner.userID, partIndex: 0, kind: .tapback(.love))])
        try await owner.submit(HomeIntent(op: .removeReaction(message: reply.id, conversation: conversation,
                                                              reaction: .tapback(.love), partIndex: 0)))
        try await owner.submit(HomeIntent(op: .editMessage(message: messages[0].id, conversation: conversation,
                                                           parts: [.text("fixed")])))
        page = try await owner.snapshot(of: conversation, tail: 10)
        #expect(page.messages[1].reactions.isEmpty)
        #expect(page.messages[0].plainText == "fixed")
        #expect(page.messages[0].editedAt != nil)
        await #expect(throws: HomeRejection.notAuthorized) {
            try await owner.submit(HomeIntent(op: .retractMessage(message: reply.id, conversation: self.conversation)))
        }
        try await owner.submit(HomeIntent(op: .retractMessage(message: messages[0].id, conversation: conversation)))
        page = try await owner.snapshot(of: conversation, tail: 10)
        #expect(page.messages[0].isRetracted)
    }

    @Test func threadReplyGetsAnAnswerInTheThread() async throws {
        let brain = FakeBrain { request, continuation in
            continuation.yield(.textDelta("re: \(request.userText)"))
            continuation.yield(.textSegmentEnd)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("root topic", to: owner)
        let root = try await ChiefFixture.idleMessages(owner, count: 2)[0]
        try await ChiefFixture.send("in thread", to: owner, threadRoot: root.id)
        let messages = try await ChiefFixture.idleMessages(owner, count: 4)
        #expect(messages[2].threadRoot == root.id)
        #expect(messages[3].threadRoot == root.id)
        #expect(messages[3].plainText == "re: in thread")
        #expect(await brain.log.requests.last?.replyContext == "root topic")

        let thread = try await owner.thread(of: conversation, root: root.id, after: 0, limit: 10)
        #expect(thread.root.id == root.id)
        #expect(thread.replies.map(\.plainText) == ["in thread", "re: in thread"])
        #expect(thread.summary.replyCount == 2)
        #expect(thread.hasMore == false)
        let page = try await owner.snapshot(of: conversation, tail: 10)
        #expect(page.threads.first { $0.root == root.id }?.replyCount == 2)
        await #expect(throws: HomeRejection.invalid("unknown_reply_target")) {
            try await ChiefFixture.send("nested", to: owner, threadRoot: messages[2].id)
        }
    }

    @Test func readCursorPinMuteAndSearch() async throws {
        let owner = try ChiefFixture().owner(.replying(["The Answer is 42"]))
        try await ChiefFixture.send("what is the answer", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        try await owner.submit(HomeIntent(op: .setReadCursor(conversation: conversation, seq: 2)))
        try await owner.submit(HomeIntent(op: .setMuted(conversation: conversation, muted: true)))
        try await owner.submit(HomeIntent(op: .setPinned(conversation: conversation, rank: nil)))
        let summary = try await owner.snapshot(of: conversation, tail: 1).conversation
        #expect(summary.readCursors[ChiefConversationOwner.userID] == 2)
        #expect(summary.muted)
        #expect(summary.pinRank == nil)
        let hits = await owner.search("ANSWER", limit: 10)
        #expect(hits.count == 2)
        #expect(hits.first?.message.plainText == "The Answer is 42")
        #expect(hits.first?.highlights == [4..<10])
        await #expect(throws: HomeRejection.invalid("unsupported")) {
            try await ChiefLocalSource(owner: owner).resolve(ContactAddress.email("a@b.co"))
        }
    }

    @Test func approvalsReachTheBrain() async throws {
        let gate = Gate()
        let brain = FakeBrain { _, continuation in
            continuation.yield(.approvalRequested(id: "perm-1", prompt: "Run rm?", options: ["Allow", "Deny"]))
            await gate.wait()
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("clean up", to: owner)
        #expect(await ChiefFixture.eventually {
            (try? await owner.snapshot(of: conversation, tail: 10).messages.count) == 2
        })
        let card = try #require(await owner.pendingApproval(in: conversation))
        await #expect(throws: HomeRejection.invalid("invalid_choice")) {
            try await owner.answerApproval(conversation: self.conversation, message: card.message, part: card.part, choice: "Maybe")
        }
        try await owner.answerApproval(conversation: conversation, message: card.message, part: card.part, choice: "Allow")
        #expect(await brain.log.approvals.map { "\($0.id):\($0.choice)" } == ["perm-1:Allow"])
        let message = try await owner.snapshot(of: conversation, tail: 10).messages[1]
        guard case .approval(let ref) = message.parts.first else { Issue.record("no approval part"); return }
        #expect(ref.decided == "Allow")
        await gate.open()
    }

    @Test func attachmentsAreStoredAndPassedToTheBrain() async throws {
        let fixture = ChiefFixture()
        let brain = FakeBrain.replying(["Nice picture"])
        let owner = try fixture.owner(brain)
        let source = ChiefLocalSource(owner: owner)
        let bytes = Data("not really a png".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chief-\(UUID().uuidString).png")
        try bytes.write(to: file)
        let hash = try Self.sha256(file)
        let ref = AttachmentRef(hash: hash, name: "photo.png", mimeType: "image/png", byteCount: bytes.count)
        let stored = try await source.upload(AttachmentUpload(conversation: conversation, fileURL: file, ref: ref))
        #expect(stored.hash == hash)
        let fetched = try await source.fetch(ref, at: AttachmentLocation(conversation: conversation), variant: .original)
        #expect(try Data(contentsOf: fetched) == bytes)
        #expect(fetched.path.hasPrefix(fixture.home.blobsDirectory.path))

        var wrong = ref
        wrong.hash = String(repeating: "0", count: 64)
        await #expect(throws: HomeRejection.invalid("hash_mismatch")) {
            try await source.upload(AttachmentUpload(conversation: self.conversation, fileURL: file, ref: wrong))
        }

        try await owner.submit(HomeIntent(op: .sendMessage(conversation: conversation,
                                                           parts: [.attachment(ref), .text("look")])))
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        let request = try #require(await brain.log.requests.first)
        #expect(request.attachmentPaths == [fetched])
        #expect(request.userText == "look")
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
