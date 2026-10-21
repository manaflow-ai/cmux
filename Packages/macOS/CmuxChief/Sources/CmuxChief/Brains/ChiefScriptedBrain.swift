#if DEBUG
public import CmuxHomeCore
import Foundation

/// A DEBUG-only ``ChiefBrain`` that replays a fixed, realistic turn so
/// dogfood tours and screenshots reach every transcript state without model
/// credentials or a network.
///
/// Every turn types, streams a short first segment, runs one tool call
/// (running, then done) and streams an answer. The user's text picks a
/// variant (case-insensitive):
///
/// - contains `approve`: after the first segment the turn asks for approval
///   and waits for ``respond(toApproval:choice:conversation:)``; `Allow` runs
///   the command, anything else declines.
/// - contains `two tools`: two tool calls back to back (``treeCommand``, then
///   ``sidebarCommand``), so the transcript folds them into one
///   "Ran 2 commands" run.
/// - starts with `remember`: a memory turn. Chief says it will save the
///   fact, runs ``memoryCommand(for:)`` (`cmux chief memory add "<fact>"`),
///   saves the fact to the turn's Chief home when the request names one
///   (`CMUX_CHIEF_HOME`, so the memory notice shows), and confirms it.
/// - contains `error`: the (last) tool call fails and the turn fails.
/// - otherwise: the answer, one of ``answers`` in turn, counting only the
///   turns that are not approval turns, so consecutive answers never repeat
///   even with an approval turn between them.
///
/// Pacing goes through the injected clock: a real clock gives the timing a
/// person sees, a test clock runs the script at once.
public final class ChiefScriptedBrain: ChiefBrain {
    /// One thing the script does.
    public enum Step: Sendable, Equatable {
        /// Waits before the next step (intentional pacing, not synchronization).
        case pause(Duration)
        /// Reports an event.
        case event(ChiefTurnEvent)
        /// Asks for approval `id` and continues with `allowed` or `denied`.
        indirect case approval(id: String, prompt: String, allowed: [Step], denied: [Step])
        /// Saves a fact to the request's Chief memory, as `cmux chief memory add` does.
        case saveMemory(String)
    }

    /// The approval buttons the script offers (its cards add the command's Always Allow rule).
    public static let approvalOptions = ChiefToolPolicy.approvalOptions
    /// The command the scripted tool call shows.
    public static let treeCommand = "cmux tree --all --json"
    /// The second command of a `two tools` turn.
    public static let sidebarCommand = "cmux sidebar-state --json"
    /// The command the approval asks to run: the dispatch verb the system prompt teaches.
    public static let approvalCommand = "cmux chief dispatch --agent codex --name Scratch --wait-working -- 'Run the test suite and report what fails.'"

    private let clock: any Clock<Duration>
    private let allowRules: ChiefAllowRules?
    private let state = ScriptedBrainState()

    /// - Parameter clock: Paces the script; tests pass a clock that returns at once.
    public init(clock: any Clock<Duration> = HomeSleepClock(), allowRules: ChiefAllowRules? = nil) {
        self.clock = clock
        self.allowRules = allowRules
    }

    // MARK: Script

    /// The steps of one turn.
    ///
    /// - Parameters:
    ///   - userText: The user's message.
    ///   - turn: The brain's turn number, from 1.
    ///   - approval: The approval number for an approval turn, from 1 (its id
    ///     is `scripted-approval-<n>`).
    public static func script(for userText: String, turn: Int, approval: Int) -> [Step] {
        let text = userText.lowercased()
        let tool = "scripted-tool-\(turn)"
        var steps: [Step] = [.pause(.milliseconds(900))]
        if text.contains("approve") {
            steps += stream("On it. That starts a coding agent, so I'll ask first.")
            steps.append(.pause(.milliseconds(300)))
            let run = "scripted-tool-\(turn)-run"
            let allowed: [Step] = [
                .event(.toolStarted(id: run, title: approvalCommand, detail: nil)),
                .pause(.milliseconds(1200)),
                .event(.toolFinished(id: run, ok: true, preview: "Codex is working in Scratch")),
                .pause(.milliseconds(400)),
            ] + stream("Done. Codex is working in Scratch.") + [.event(.finished)]
            let denied: [Step] = stream("Okay, I left everything as it was.") + [.event(.finished)]
            // The real brains' command prompt ("Run `<command>`?", ChiefToolPolicy.claudePrompt), so the
            // card shows "Chief wants to run", the command block and the Always Allow menu.
            steps.append(.approval(id: "scripted-approval-\(approval)",
                                   prompt: "Run `\(approvalCommand)`?",
                                   allowed: allowed, denied: denied))
            return steps
        }
        if let fact = rememberedFact(in: userText) {
            let save = "scripted-tool-\(turn)-memory"
            // As the prompt coaches (ChiefSystemPrompt.memoryRules): one short acknowledgement, no
            // second "Saved: …" bubble; the note's row ("Chief will remember: … · Undo") confirms it.
            steps += stream("Got it.")
            steps += [
                .pause(.milliseconds(300)),
                .event(.toolStarted(id: save, title: memoryCommand(for: fact), detail: "Saving one fact to Chief's memory")),
                .pause(.milliseconds(900)),
                .saveMemory(fact),
                .event(.toolFinished(id: save, ok: true, preview: "Saved")),
                .pause(.milliseconds(400)),
            ]
            steps.append(.event(.finished))
            return steps
        }
        steps += stream(text.contains("error") ? "Let me check what's failing." : "On it. Let me look at what's running.")
        steps.append(.pause(.milliseconds(300)))
        var calls: [(id: String, title: String, detail: String, preview: String)] = [
            (tool, treeCommand, "Reading every window, workspace and pane", "3 workspaces, 4 panes, 2 agents"),
        ]
        if text.contains("two tools") {
            calls.append(("\(tool)-sidebar", sidebarCommand, "Reading the sidebar's rows", "4 workspaces, 1 unread"))
        }
        for (index, call) in calls.enumerated() {
            steps += [
                .event(.toolStarted(id: call.id, title: call.title, detail: call.detail)),
                .pause(.milliseconds(1600)),
            ]
            if text.contains("error"), index == calls.count - 1 {
                steps += [
                    .event(.toolFinished(id: call.id, ok: false, preview: "The control socket closed")),
                    .pause(.milliseconds(300)),
                    .event(.failed("The cmux control socket closed before the tree came back.")),
                ]
                return steps
            }
            steps += [
                .event(.toolFinished(id: call.id, ok: true, preview: call.preview)),
                .pause(.milliseconds(index == calls.count - 1 ? 500 : 200)),
            ]
        }
        // Approval turns take no answer, so they do not advance the rotation.
        steps += stream(answer(turn: turn - approval))
        steps.append(.event(.finished))
        return steps
    }

    /// The fact a `remember` turn saves: the message after "Remember (that)",
    /// in the third person when it starts with "I" ("I prefer 14 pt font"
    /// becomes "Prefers 14 pt font"); nil for any other message.
    public static func rememberedFact(in userText: String) -> String? {
        var rest = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.lowercased().hasPrefix("remember") else { return nil }
        rest = String(rest.dropFirst("remember".count)).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") || rest.hasPrefix(",") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if rest.lowercased() == "that" || rest.lowercased().hasPrefix("that ") { rest = String(rest.dropFirst(4)) }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        let thirdPerson = ["i prefer ": "Prefers ", "i use ": "Uses ", "i like ": "Likes ", "i want ": "Wants "]
        for (first, replacement) in thirdPerson where rest.lowercased().hasPrefix(first) {
            rest = replacement + rest.dropFirst(first.count)
        }
        guard let head = rest.first else { return nil }
        return head.uppercased() + rest.dropFirst()
    }

    /// The command a `remember` turn shows: `cmux chief memory add "<fact>"`,
    /// the fact double-quoted for a POSIX shell.
    public static func memoryCommand(for fact: String) -> String {
        var quoted = ""
        for character in fact {
            if "\\\"$`".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return "cmux chief memory add \"\(quoted)\""
    }

    /// The answers a plain turn ends with, in rotation.
    public static let answers = [
        "Here's the picture: Build has Claude Code finishing a test run, Docs has Codex waiting on your review, "
            + "and Scratch is idle. Want me to nudge the one that's waiting?",
        "Noted. Nothing else needs you right now, and I'll ping you when Docs finishes its review.",
        "Build's test run just finished green. Docs is still waiting on your review; Scratch hasn't moved.",
        "All quiet: no agent is waiting on you. I'll keep an eye on Docs and tell you when it changes.",
    ]

    /// The last segment's text for the `number`th answered turn, from 1.
    public static func answer(turn number: Int) -> String {
        answers[(max(1, number) - 1) % answers.count]
    }

    /// One text segment streamed a word at a time.
    static func stream(_ text: String) -> [Step] {
        var steps: [Step] = []
        for (index, word) in words(text).enumerated() {
            if index > 0 { steps.append(.pause(.milliseconds(60))) }
            steps.append(.event(.textDelta(word)))
        }
        steps.append(.event(.textSegmentEnd))
        return steps
    }

    /// `text` in chunks that join back to it: each word with the space before it.
    static func words(_ text: String) -> [String] {
        var chunks: [String] = []
        for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            chunks.append(index == 0 ? String(word) : " " + word)
        }
        return chunks
    }

    // MARK: ChiefBrain

    public func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
        let clock = clock
        let state = state
        return AsyncThrowingStream { continuation in
            // task-owner: one scripted turn; cancelled by the stream's termination (Stop)
            let task = Task {
                let numbers = await state.nextTurn(request.conversation,
                                                   isApproval: request.userText.lowercased().contains("approve"))
                let steps = Self.script(for: request.userText, turn: numbers.turn, approval: numbers.approval)
                do {
                    try await Self.play(steps, conversation: request.conversation, clock: clock, state: state,
                                        environment: request.environment, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func play(_ steps: [Step], conversation: ConversationID, clock: any Clock<Duration>,
                             state: ScriptedBrainState, environment: [String: String],
                             continuation: AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation) async throws {
        for step in steps {
            try Task.checkCancellation()
            switch step {
            case .pause(let duration):
                try await clock.sleep(for: duration)
            case .event(let event):
                continuation.yield(event)
            case .approval(let id, let prompt, let allowed, let denied):
                // The real brains' options: the Always Allow rule rides along (ChiefToolPolicy.approvalOptions(command:)).
                continuation.yield(.approvalRequested(id: id, prompt: prompt,
                                                       options: ChiefToolPolicy.approvalOptions(command: ChiefAllowRules.command(inPrompt: prompt))))
                let choice = await withTaskCancellationHandler {
                    await state.awaitChoice(id: id, conversation: conversation)
                } onCancel: {
                    // task-owner: one hop to release a waiting approval; ends at once
                    Task { await state.cancel(conversation: conversation) }
                }
                guard let choice else { throw CancellationError() }
                let next = choice.caseInsensitiveCompare("Allow") == .orderedSame ? allowed : denied
                try await play(next, conversation: conversation, clock: clock, state: state,
                               environment: environment, continuation: continuation)
            case .saveMemory(let fact):
                // A fixture: with no Chief home (tests) or a failed write, the turn still reads as saved.
                guard let root = environment[ChiefHome.environmentKey], !root.isEmpty else { continue }
                let home = ChiefHome(root: URL(fileURLWithPath: root, isDirectory: true))
                _ = try? ChiefMemory(paths: ChiefMemoryPaths(home: home)).add(fact, source: "chief")
            }
        }
    }

    public func respond(toApproval id: String, choice: String, conversation: ConversationID) async {
        await state.answer(id: id, choice: choice)
    }

    public func interrupt(conversation: ConversationID) async {
        await state.cancel(conversation: conversation)
    }

    public func shutdown() async {
        await state.cancelAll()
    }
}

/// The scripted brain's counters and the approvals it waits on.
private actor ScriptedBrainState {
    private var turns = 0
    private var approvals = 0
    /// Answers that arrived before the turn started waiting.
    private var early: [String: String] = [:]
    /// Conversations interrupted while not waiting; their running turn stops at its approval.
    private var interrupted: Set<ConversationID> = []
    private var waiting: [ConversationID: (id: String, continuation: CheckedContinuation<String?, Never>)] = [:]

    func nextTurn(_ conversation: ConversationID, isApproval: Bool) -> (turn: Int, approval: Int) {
        interrupted.remove(conversation)
        turns += 1
        if isApproval { approvals += 1 }
        return (turns, approvals)
    }

    func awaitChoice(id: String, conversation: ConversationID) async -> String? {
        if let choice = early.removeValue(forKey: id) { return choice }
        if Task.isCancelled || interrupted.remove(conversation) != nil { return nil }
        return await withCheckedContinuation { continuation in
            waiting[conversation]?.continuation.resume(returning: nil)
            waiting[conversation] = (id, continuation)
        }
    }

    func answer(id: String, choice: String) {
        guard let entry = waiting.first(where: { $0.value.id == id }) else {
            early[id] = choice
            return
        }
        waiting[entry.key] = nil
        entry.value.continuation.resume(returning: choice)
    }

    func cancel(conversation: ConversationID) {
        guard let entry = waiting.removeValue(forKey: conversation) else {
            interrupted.insert(conversation)
            return
        }
        entry.continuation.resume(returning: nil)
    }

    func cancelAll() {
        let all = waiting.values
        waiting.removeAll()
        for entry in all { entry.continuation.resume(returning: nil) }
    }
}
#endif
