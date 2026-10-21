#if DEBUG
import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// A clock whose sleeps return at once and are recorded.
final class RecordingImmediateClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var slept: [Duration] = []

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    var sleeps: [Duration] { lock.withLock { slept } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock { slept.append(deadline.offset) }
    }
}

@Suite struct ChiefScriptedBrainTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    func request(_ text: String) -> ChiefTurnRequest {
        ChiefTurnRequest(conversation: conversation, resumeSession: nil, userText: text, attachmentPaths: [],
                         replyContext: nil, systemPrompt: "", workingDirectory: FileManager.default.temporaryDirectory,
                         environment: [:])
    }

    /// The segments' text (deltas joined per segment) and the other events, in order.
    func summarize(_ events: [ChiefTurnEvent]) -> [String] {
        var out: [String] = []
        var text = ""
        for event in events {
            switch event {
            case .textDelta(let delta): text += delta
            case .textSegmentEnd:
                out.append("text: \(text)")
                text = ""
            case .toolStarted(_, let title, _): out.append("tool: \(title)")
            case .toolFinished(_, let ok, let preview): out.append("tool \(ok ? "done" : "failed"): \(preview ?? "")")
            case .approvalRequested(let id, _, let options): out.append("approval \(id): \(options.joined(separator: "/"))")
            case .finished: out.append("finished")
            case .failed(let message): out.append("failed: \(message)")
            case .session, .question, .result, .usage: out.append("other")
            }
        }
        return out
    }

    @Test func plainTurnStreamsTextRunsTheTreeToolThenAnswers() async throws {
        let clock = RecordingImmediateClock()
        let brain = ChiefScriptedBrain(clock: clock)
        var events: [ChiefTurnEvent] = []
        for try await event in brain.run(request("What are my agents doing?")) { events.append(event) }

        #expect(summarize(events) == [
            "text: On it. Let me look at what's running.",
            "tool: \(ChiefScriptedBrain.treeCommand)",
            "tool done: 3 workspaces, 4 panes, 2 agents",
            "text: \(expectedAnswer(turn: 1))",
            "finished",
        ])
        // Streamed word by word, not as one delta.
        #expect(events.filter { if case .textDelta = $0 { return true }; return false }.count > 10)
        // Paced in real time through the clock: typing first, then the stream.
        #expect(clock.sleeps.first == .milliseconds(900))
        #expect(clock.sleeps.reduce(.zero, +) > .seconds(4))
    }

    @Test func consecutiveTurnsEndWithDifferentAnswers() async throws {
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var last: [String] = []
        for text in ["first", "second"] {
            var events: [ChiefTurnEvent] = []
            for try await event in brain.run(request(text)) { events.append(event) }
            last.append(summarize(events).dropLast().last ?? "")
        }
        #expect(last == ["text: \(expectedAnswer(turn: 1))", "text: \(expectedAnswer(turn: 2))"])
        #expect(last[0] != last[1])
    }

    /// An approval turn between two plain turns does not make them repeat
    /// (the rotation counts answered turns, not every turn).
    @Test func followUpsAfterAnApprovalStillDiffer() async throws {
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var answers: [String] = []
        for text in ["What's up?", "approve it", "Anything else?", "And now?"] {
            var events: [ChiefTurnEvent] = []
            for try await event in brain.run(request(text)) {
                events.append(event)
                if case .approvalRequested(let id, _, _) = event {
                    await brain.respond(toApproval: id, choice: "Deny", conversation: conversation)
                }
            }
            if !text.contains("approve") { answers.append(summarize(events).dropLast().last ?? "") }
        }
        #expect(answers == (1...3).map { "text: \(expectedAnswer(turn: $0))" })
        #expect(Set(answers).count == 3)
    }

    @Test func twoToolsTurnRunsBothCallsBackToBack() async throws {
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var events: [ChiefTurnEvent] = []
        for try await event in brain.run(request("Use TWO TOOLS please")) { events.append(event) }
        #expect(summarize(events) == [
            "text: On it. Let me look at what's running.",
            "tool: \(ChiefScriptedBrain.treeCommand)",
            "tool done: 3 workspaces, 4 panes, 2 agents",
            "tool: \(ChiefScriptedBrain.sidebarCommand)",
            "tool done: 4 workspaces, 1 unread",
            "text: \(expectedAnswer(turn: 1))",
            "finished",
        ])
        // Distinct call ids, so the owner posts two work messages that the transcript folds.
        let ids = events.compactMap { event -> String? in
            if case .toolStarted(let id, _, _) = event { return id }
            return nil
        }
        #expect(ids.count == 2 && Set(ids).count == 2)
    }

    @Test func twoToolsErrorFailsTheLastCall() async throws {
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var events: [ChiefTurnEvent] = []
        for try await event in brain.run(request("two tools then an error")) { events.append(event) }
        #expect(summarize(events).suffix(3) == [
            "tool: \(ChiefScriptedBrain.sidebarCommand)",
            "tool failed: The control socket closed",
            "failed: The cmux control socket closed before the tree came back.",
        ])
    }

    @Test(arguments: zip(["Allow", "Deny"], [true, false]))
    func approveTurnWaitsForTheAnswer(choice: String, allowed: Bool) async throws {
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var events: [ChiefTurnEvent] = []
        var answered = false
        for try await event in brain.run(request("Please APPROVE this")) {
            events.append(event)
            if case .approvalRequested(let id, let prompt, let options) = event {
                #expect(id == "scripted-approval-1")
                #expect(ChiefAllowRules.command(inPrompt: prompt) == ChiefScriptedBrain.approvalCommand)
                // The real brains' options: the dispatch card offers Always Allow "cmux chief dispatch".
                #expect(options == ["Allow", "Deny", "always:cmux chief dispatch"])
                answered = true
                await brain.respond(toApproval: id, choice: choice, conversation: conversation)
            }
        }
        #expect(answered)
        let head = [
            "text: On it. That starts a coding agent, so I'll ask first.",
            "approval scripted-approval-1: Allow/Deny/always:cmux chief dispatch",
        ]
        let tail = allowed
            ? ["tool: \(ChiefScriptedBrain.approvalCommand)", "tool done: Codex is working in Scratch",
               "text: Done. Codex is working in Scratch.", "finished"]
            : ["text: Okay, I left everything as it was.", "finished"]
        #expect(summarize(events) == head + tail)
    }

    @Test func errorTurnFailsItsToolAndTheTurn() async throws {
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var events: [ChiefTurnEvent] = []
        for try await event in brain.run(request("show me an error")) { events.append(event) }
        #expect(summarize(events) == [
            "text: Let me check what's failing.",
            "tool: \(ChiefScriptedBrain.treeCommand)",
            "tool failed: The control socket closed",
            "failed: The cmux control socket closed before the tree came back.",
        ])
    }

    /// A "Remember …" turn answers about memory and runs `cmux chief memory add` itself.
    @Test func rememberTurnSavesTheFactThroughTheMemoryCommand() async throws {
        let home = ChiefFixture().home
        var turn = request("Remember that I prefer 14 pt font.")
        turn.environment = [ChiefHome.environmentKey: home.root.path]
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var events: [ChiefTurnEvent] = []
        for try await event in brain.run(turn) { events.append(event) }
        #expect(summarize(events) == [
            "text: Got it.",
            "tool: cmux chief memory add \"Prefers 14 pt font\"",
            "tool done: Saved",
            "finished",
        ])
        #expect(ChiefMemory(paths: ChiefMemoryPaths(home: home)).facts().map(\.text) == ["Prefers 14 pt font"])
    }

    @Test func rememberedFactAndItsCommand() {
        #expect(ChiefScriptedBrain.rememberedFact(in: "What are my agents doing?") == nil)
        #expect(ChiefScriptedBrain.rememberedFact(in: "remember: builds run on brave-otter")
            == "Builds run on brave-otter")
        #expect(ChiefScriptedBrain.rememberedFact(in: "Remember that ") == nil)
        #expect(ChiefScriptedBrain.memoryCommand(for: #"Say "hi" for $5"#)
            == #"cmux chief memory add "Say \"hi\" for \$5""#)
    }

    @Test func interruptReleasesAWaitingApproval() async throws {
        let brain = ChiefScriptedBrain(clock: RecordingImmediateClock())
        var sawApproval = false
        var ended = false
        do {
            for try await event in brain.run(request("approve")) {
                if case .approvalRequested = event {
                    sawApproval = true
                    await brain.interrupt(conversation: conversation)
                }
                #expect(event != .finished)
            }
            ended = true
        } catch is CancellationError {
            ended = true
        }
        #expect(sawApproval)
        #expect(ended)
    }

    /// Through the owner: the user's message, the first segment, the tool
    /// as a done work message, then the answer.
    @Test func ownerPostsEveryScriptedPart() async throws {
        let home = ChiefFixture().home
        let owner = try ChiefConversationOwner(home: home, brain: ChiefScriptedBrain(clock: RecordingImmediateClock()),
                                               userDisplayName: "Tester", now: { Date() }) { _ in
            ChiefTurnContext(systemPrompt: "", workingDirectory: home.root, environment: [:])
        }
        try await ChiefFixture.send("What are my agents doing?", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 4)
        #expect(messages.map(\.plainText).first == "What are my agents doing?")
        #expect(messages.dropFirst().first?.plainText == "On it. Let me look at what's running.")
        let work = messages.flatMap(\.parts).compactMap { part -> WorkRef? in
            if case .work(let work) = part { return work }
            return nil
        }
        #expect(work.map(\.title) == [ChiefScriptedBrain.treeCommand])
        #expect(work.map(\.status) == [.done])
        #expect(messages.last?.plainText == expectedAnswer(turn: 1))
        await owner.shutdown()
    }

    func expectedAnswer(turn: Int) -> String {
        ChiefScriptedBrain.answers[(turn - 1) % ChiefScriptedBrain.answers.count]
    }
}
#endif
