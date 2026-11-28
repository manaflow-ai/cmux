import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// The owner's system rows and typing around them: a failed turn posts an error row (not a Chief
/// bubble) that Try Again answers by running the last message again; a saved memory note posts a
/// row after the turn that saved it (or at once outside one); no typing dots while a tool runs.
@Suite struct ChiefTurnNoticesTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    private static func work(_ message: Message?) -> WorkRef? {
        guard case .work(let work)? = message?.parts.first else { return nil }
        return work
    }

    @Test func aFailedTurnPostsAnErrorRow() async throws {
        let owner = try ChiefFixture().owner(.events([.textDelta("Partial"), .failed("the socket closed")]))
        try await ChiefFixture.send("hi", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 3)
        let row = try #require(Self.work(messages.last))
        #expect(row.session.hasPrefix(ChiefConversationOwner.failureSessionPrefix))
        #expect(row.status == .failed && row.host == nil)
        #expect(row.title.contains("the socket closed"))
        #expect(messages.last?.author == ChiefConversationOwner.chiefID)
    }

    @Test func tryAgainRunsTheLastMessageAgain() async throws {
        let brain = FakeBrain { request, continuation in
            continuation.yield(.textDelta("re: \(request.userText.contains("hi") ? "hi" : "?")"))
            continuation.yield(.failed("boom"))
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("hi", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 3)
        #expect(await owner.retryLastTurn(conversation: conversation))
        #expect(await ChiefFixture.eventually { await brain.log.requests.count == 2 })
        let messages = try await ChiefFixture.idleMessages(owner, count: 5)
        // The user's message shows once; the second turn read the same text.
        #expect(messages.filter { $0.author == ChiefConversationOwner.userID }.count == 1)
        #expect(await brain.log.requests.last?.userText.contains("hi") == true)
    }

    @Test func tryAgainWaitsForTheRunningTurn() async throws {
        let gate = Gate()
        let brain = FakeBrain { _, continuation in
            await gate.wait()
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        #expect(await owner.retryLastTurn(conversation: conversation) == false) // nothing to resend
        try await ChiefFixture.send("hi", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWorking(conversation) })
        #expect(await owner.retryLastTurn(conversation: conversation) == false)
        await gate.open()
    }

    @Test func noTypingDotsWhileAToolRuns() async throws {
        let gate = Gate()
        let brain = FakeBrain { _, continuation in
            continuation.yield(.toolStarted(id: "t1", title: "cmux tree --all", detail: "cmux tree --all"))
            await gate.wait()
            continuation.yield(.toolFinished(id: "t1", ok: true, preview: "3 workspaces"))
            continuation.yield(.textDelta("Done"))
            continuation.yield(.textSegmentEnd)
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        let recorder = EventRecorder()
        await recorder.start(owner)
        try await ChiefFixture.send("look", to: owner)
        #expect(await ChiefFixture.eventually { await recorder.messages().contains { Self.work($0)?.status == .running } })
        @Sendable func typingAfterTool(_ events: [HomeEvent]) -> [Bool] {
            guard let posted = events.firstIndex(where: {
                if case .message(let m, _) = $0 { return Self.work(m)?.status == .running }
                return false
            }) else { return [] }
            return events.dropFirst(posted + 1).compactMap { if case .typing(_, _, on: let on) = $0 { return on }; return nil }
        }
        // The tool's post turns the dots off, and nothing turns them on while it runs.
        let whileRunning = typingAfterTool(await recorder.events)
        #expect(whileRunning.first == false && whileRunning.contains(true) == false)
        await gate.open()
        // Between the finished tool and the next words the Chief types again.
        #expect(await ChiefFixture.eventually { typingAfterTool(await recorder.events).contains(true) })
        _ = try await ChiefFixture.idleMessages(owner, count: 3)
    }

    @Test func aNoteSavedDuringATurnPostsAfterTheTurn() async throws {
        let gate = Gate()
        let brain = FakeBrain { _, continuation in
            await gate.wait()
            continuation.yield(.textDelta("Noted."))
            continuation.yield(.textSegmentEnd)
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("Remember that I prefer 14 pt font", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWorking(conversation) })
        await owner.noteMemorySaved(conversation: conversation, fact: "m-1", text: "Prefers 14 pt font")
        await owner.noteMemorySaved(conversation: conversation, fact: "m-1", text: "Prefers 14 pt font") // a second view
        #expect(try await owner.snapshot(of: conversation, tail: 10).messages.count == 1)
        await gate.open()
        let messages = try await ChiefFixture.idleMessages(owner, count: 3)
        #expect(messages.count == 3)
        let row = try #require(Self.work(messages.last))
        #expect(row.session == ChiefConversationOwner.memorySessionPrefix + "t:m-1")
        #expect(row.title == "Prefers 14 pt font" && row.status == .done)

        #expect(await owner.noteMemoryForgotten(conversation: conversation, fact: "m-1"))
        let undone = try await owner.snapshot(of: conversation, tail: 10).messages.last
        #expect(Self.work(undone)?.status == .failed)
    }

    @Test func aNoteSavedOutsideATurnPostsAtOnce() async throws {
        let owner = try ChiefFixture().owner(.replying(["hi"]))
        await owner.noteMemorySaved(conversation: conversation, fact: "m-2", text: "Uses zsh")
        await owner.noteMemorySaved(conversation: conversation, fact: "m-2", text: "Uses zsh")
        let messages = try await owner.snapshot(of: conversation, tail: 10).messages
        #expect(messages.count == 1)
        #expect(Self.work(messages.first)?.session == ChiefConversationOwner.memorySessionPrefix + "s:m-2")
    }
}
