// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxAgentQuestion
import CmuxMobileModel
import Foundation

/// An offline `AgentSessionSource` that streams a realistic Claude Code style
/// session: history, thinking, grouped reads and searches, a plan that
/// progresses, edits with diffs, a command with output, a permission request,
/// a multi-item AskUserQuestion, and a final answer with a table, code and math.
/// Timing goes through an injected `sleep` so tests can run it instantly.
@MainActor
public final class MockAgentSession: AgentSessionSource {
    public let summary: AgentSessionSummary
    let sleep: @Sendable (Duration) async throws -> Void
    private var continuation: AsyncStream<AgentSessionEvent>.Continuation?
    private var running: Task<Void, Never>?
    private var turnCount = 0
    private var permissionWaiter: CheckedContinuation<String?, Never>?
    private var questionWaiter: CheckedContinuation<AgentQuestionAnswer?, Never>?
    private var pendingPermissionID: String?
    private var pendingQuestionID: String?
    private var richTurnUsed = false
    private var queued: [(id: String, text: String, attachments: [AgentAttachment])] = []
    private var currentModel = "opus-5.5"
    private var effort = "medium"
    private var mode = "default"
    private let richFirstTurn: Bool
    /// false: a brand-new session (no earlier turns to replay).
    private let history: Bool
    /// Events collected while replaying, sent as one `.batch`.
    private var batch: [AgentSessionEvent]?
    /// Checkpoints recorded around turns (newest last).
    var checkpointLog: [AgentCheckpoint] = []
    /// Characters per streamed chunk and the delay between chunks (≈ 40 chars / 50 ms).
    public var chunkSize = 6
    public var chunkDelay: Duration = .milliseconds(16)

    public init(
        summary: AgentSessionSummary, richFirstTurn: Bool = true, history: Bool = true,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.summary = summary
        self.richFirstTurn = richFirstTurn
        self.history = history
        self.sleep = sleep
    }

    public func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        // History (and a waiting turn's opening) arrive as one change.
        batch = []
        replayHistory()
        if summary.status == .waiting { startWaitingTurn() }
        let replayed = batch ?? []
        batch = nil
        continuation.yield(.batch(replayed))
        return stream
    }

    public func send(_ intent: AgentClientIntent) {
        switch intent {
        case .prompt(let text, let attachments, let steer, _, _):
            let promptID = UUID().uuidString
            if running != nil, !steer {
                queued.append((promptID, text, attachments))
                emit(.queued(text: text, promptId: promptID, position: queued.count))
            } else {
                startTurn(text: text, attachments: attachments, promptID: promptID)
            }
        case .retryFailedTurn:
            emit(.clientError("This demo has no failed turn to retry."))
        case .cancel:
            running?.cancel()
            // A turn waiting on the person ends too (an agent cancels its
            // outstanding request when the prompt is cancelled).
            if let id = pendingPermissionID { emit(.permissionDecision(permissionId: id, optionId: nil)) }
            pendingPermissionID = nil
            pendingQuestionID = nil
            permissionWaiter?.resume(returning: nil)
            permissionWaiter = nil
            questionWaiter?.resume(returning: nil)
            questionWaiter = nil
        case .respondPermission(let id, let optionID):
            guard id == pendingPermissionID else { return }
            // DEBUG: an allow waits for mock "Face ID" (Settings → Developer), so the
            // waiting state shows. A deny never waits.
            let delay = DeveloperOptions.mockFaceIDDelay
            if delay > .zero, let optionID, !optionID.lowercased().contains("deny"), !optionID.lowercased().contains("reject") {
                Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self, id == self.pendingPermissionID else { return }
                    self.decide(permission: id, optionID: optionID)
                }
                return
            }
            decide(permission: id, optionID: optionID)
        case .answerQuestion(let id, let answer):
            guard id == pendingQuestionID else { return }
            emit(.questionAnswered(questionId: id, answer: answer))
            pendingQuestionID = nil
            questionWaiter?.resume(returning: answer)
            questionWaiter = nil
        case .setModel(let id):
            currentModel = id
            emit(.modelsAvailable(Self.models, current: id))
        case .retryWithModel(let model, let text, let attachments, let promptID):
            send(.setModel(model))
            send(.prompt(text: text, attachments: attachments, steer: false, promptID: promptID, resend: false))
        case .setMode(let id):
            mode = id
            emit(.update(.currentMode(id)))
        case .setConfigOption(let id, let value):
            if id == "effort" { effort = value }
            emit(.update(.configOptions(configOptions)))
        case .removeQueued(let promptID):
            queued.removeAll { $0.id == promptID }
            emit(.dequeued(promptId: promptID))
        case .editQueued(let promptID, let text):
            emit(.queueUpdated(promptId: promptID, text: text))
        case .moveQueued(let promptID, let index):
            let order = Self.moved(queued.map(\.id), promptID, to: index)
            queued.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
            emit(.queueOrder(order))
        case .sendQueuedNow(let promptID):
            queued.removeAll { $0.id == promptID }
            emit(.dequeued(promptId: promptID))
        case .resumeQueue:
            emit(.queuePaused(false, reason: nil))
        }
    }

    /// `ids` with `id` moved to `index` (acpmux `move_queued`).
    static func moved(_ ids: [String], _ id: String, to index: Int) -> [String] {
        var ids = ids
        guard let from = ids.firstIndex(of: id) else { return ids }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        return ids
    }

    private func decide(permission id: String, optionID: String?) {
        emit(.permissionDecision(permissionId: id, optionId: optionID))
        pendingPermissionID = nil
        permissionWaiter?.resume(returning: optionID)
        permissionWaiter = nil
    }

    func emit(_ event: AgentSessionEvent) {
        if batch != nil {
            batch?.append(event)
        } else {
            continuation?.yield(event)
        }
    }

    // MARK: History

    private static let models = [
        ACPModelInfo(id: "opus-5.5", name: "Opus 5.5"),
        ACPModelInfo(id: "sonnet-5.5", name: "Sonnet 5.5"),
        ACPModelInfo(id: "haiku-5", name: "Haiku 5"),
    ]

    private var configOptions: [ACPConfigOption] {
        [ACPConfigOption(id: "effort", name: "Effort", category: "thought_level", currentValue: effort, options: [
            .init(value: "low", name: "Low"), .init(value: "medium", name: "Medium"),
            .init(value: "high", name: "High"), .init(value: "max", name: "Max"),
        ])]
    }

    private func replayHistory() {
        emit(.modelsAvailable(Self.models, current: currentModel))
        emit(.modesAvailable([
            ACPMode(id: "default", name: "Manual"), ACPMode(id: "acceptEdits", name: "Accept edits"),
            ACPMode(id: "plan", name: "Plan"), ACPMode(id: "auto", name: "Auto"),
        ], current: mode))
        emit(.update(.configOptions(configOptions)))
        emit(.update(.availableCommands([
            ACPAvailableCommand(name: "review", description: "Review the current diff"),
            ACPAvailableCommand(name: "compact", description: "Summarize the conversation to free context"),
            ACPAvailableCommand(name: "init", description: "Create a CLAUDE.md for this project"),
            ACPAvailableCommand(name: "test", description: "Run the test suite", hint: "filter"),
        ])))
        emit(.update(.usage(used: history ? 48_000 : 0, size: 200_000)))
        guard history else { return }
        let start = Date().addingTimeInterval(-3600)
        let turnID = "history-1"
        emit(.userMessage(text: "What does the link framing look like today?", promptId: "p-h1", turnId: turnID, attachments: [], at: start))
        emit(.turnStarted(turnId: turnID, at: start))
        emit(.update(.toolCall(ACPToolCall(
            id: "h-read", title: "Read frame.rs", kind: .read, status: .completed,
            content: [.content(.text("pub struct Frame { len: u32, channel: u32, kind: FrameKind, payload: Bytes }"))],
            locations: [.init(path: "cmux-next-ios/rust/cmux-mobile-link/src/frame.rs")]
        ))))
        emit(.update(.agentMessageChunk(text: MockScript.historyAnswer, messageId: "h-m1")))
        emit(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: start.addingTimeInterval(41)))
        let second = Date().addingTimeInterval(-1800)
        replaySubagentTurn(at: second)
        replayStressTurns(ListStressSettings.shared.historyTurns)
        checkpointLog = [
            AgentCheckpoint(id: "cp-h1", title: "What does the link framing look like today?", turnID: turnID, createdAt: start,
                            branch: summary.branch, head: "4d81e0c", files: 0),
            AgentCheckpoint(id: "cp-h2", title: "Audit the transport switch", turnID: "history-2", createdAt: second,
                            branch: summary.branch, head: "4d81e0c", files: 3),
            AgentCheckpoint(id: "cp-h2-after", title: "Audit the transport switch", turnID: "history-2", isBeforeTurn: false,
                            createdAt: second.addingTimeInterval(41), branch: summary.branch, head: "4d81e0c", files: 5,
                            complete: false, skipped: 1),
        ]
    }

    // MARK: List stress rig

    /// `count` replayed turns shaped like real agent work (a thought, a read, an edit, a command
    /// with output, a markdown answer with code and a table), for the list scroll rig
    /// (`verify/listperf/`). The newest one edits a small file and a long one, the diff screen's case.
    private func replayStressTurns(_ count: Int) {
        guard count > 0 else { return }
        let base = Date().addingTimeInterval(-1500)
        for index in 0..<count {
            let turnID = "stress-\(index)"
            let at = base.addingTimeInterval(Double(index) * 2)
            emit(.userMessage(text: MockStressContent.prompt(index), promptId: "p-\(turnID)", turnId: turnID, attachments: [], at: at))
            emit(.turnStarted(turnId: turnID, at: at))
            emit(.update(.agentThoughtChunk(text: MockStressContent.thought(index))))
            emit(.update(.toolCall(ACPToolCall(
                id: "\(turnID)-read", title: "Read LinkDialer.swift", kind: .read, status: .completed,
                content: [.content(.text(MockStressContent.code(lines: 12, seed: index)))],
                locations: [.init(path: "CmuxMobileTransport/LinkDialer.swift")]
            ))))
            var diffs: [ACPToolCall.Content] = [.diff(path: "Sources/Stress\(index).swift",
                                                      oldText: MockStressContent.code(lines: 30, seed: index),
                                                      newText: MockStressContent.code(lines: 30, seed: index, edited: true))]
            if index == count - 1, ListStressSettings.shared.largeDiff {
                diffs.append(.diff(path: "Sources/Generated/Large.swift",
                                   oldText: MockStressContent.code(lines: MockStressContent.largeDiffLines, seed: 7),
                                   newText: MockStressContent.code(lines: MockStressContent.largeDiffLines, seed: 7, edited: true)))
            }
            emit(.update(.toolCall(ACPToolCall(id: "\(turnID)-edit", title: "Edit Stress\(index).swift", kind: .edit, status: .completed, content: diffs))))
            emit(.update(.toolCall(ACPToolCall(
                id: "\(turnID)-run", title: "swift test --filter Link", kind: .execute, status: .completed,
                content: [.content(.text(MockStressContent.testOutput(index)))],
                rawInput: .object(["command": .string("swift test --filter Link")])
            ))))
            let answer = MockStressContent.answer(index)
                + (ListStressSettings.shared.screen == "artifacts" ? "\n\n" + MockStressContent.artifacts(index) : "")
            emit(.update(.agentMessageChunk(text: answer, messageId: "\(turnID)-m")))
            emit(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: at.addingTimeInterval(1)))
        }
    }

    // MARK: Turns

    private func startTurn(text: String, attachments: [AgentAttachment], promptID: String) {
        turnCount += 1
        let turnID = "turn-\(turnCount)-\(promptID.prefix(4))"
        emit(.userMessage(text: text, promptId: promptID, turnId: turnID, attachments: attachments, at: Date()))
        emit(.turnStarted(turnId: turnID, at: Date()))
        checkpointLog.append(AgentCheckpoint(id: "cp-\(turnID)", title: text, turnID: turnID, createdAt: Date(),
                                             branch: summary.branch, head: "9f2c1ab", files: 5))
        // The first prompt the person sends gets the rich turn, even after a waiting turn.
        let rich = richFirstTurn && !richTurnUsed
        richTurnUsed = richTurnUsed || rich
        running = Task { [weak self] in
            guard let self else { return }
            do {
                if ListStressSettings.shared.streams {
                    try await self.stream(MockStressContent.streamedAnswer, messageID: "stress-stream-\(turnID)")
                } else if rich {
                    try await self.richTurn()
                } else {
                    try await self.shortTurn(prompt: text)
                }
                self.emit(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: Date()))
            } catch {
                self.permissionWaiter?.resume(returning: nil)
                self.permissionWaiter = nil
                self.questionWaiter?.resume(returning: nil)
                self.questionWaiter = nil
                self.emit(.turnResult(turnId: turnID, status: .cancelled, errorText: nil, at: Date()))
            }
            self.running = nil
            self.drainQueue()
        }
    }

    /// A session the Mac reports as waiting (`summary.status == .waiting`):
    /// a turn on the tab's task that is blocked on the person. Claude asks
    /// a question; other agents ask to run a command. Opening the tab shows
    /// the card, as the Workspaces list's "is waiting" promises.
    private func startWaitingTurn() {
        turnCount += 1
        let turnID = "turn-waiting"
        let start = Date().addingTimeInterval(-25 * 60)
        emit(.userMessage(text: summary.name, promptId: "p-waiting", turnId: turnID, attachments: [], at: start))
        emit(.turnStarted(turnId: turnID, at: start))
        let asksQuestion = summary.harness == "claude"
        if asksQuestion {
            emit(.update(.agentMessageChunk(text: MockScript.beforeQuestion, messageId: "m-waiting")))
            let question = MockScript.question(session: summary.id, id: "q-waiting")
            pendingQuestionID = question.id
            emit(.question(question))
        } else {
            let permissionID = "perm-waiting"
            pendingPermissionID = permissionID
            let call = ACPToolCall(id: "x-waiting", title: "git merge --continue", kind: .execute, status: .pending,
                                   rawInput: .object(["command": .string("git add -A && git merge --continue")]))
            emit(.update(.agentMessageChunk(text: "The conflicts are resolved in 4 files. I need to commit the merge:", messageId: "m-waiting")))
            emit(.update(.toolCall(call)))
            emit(.permissionRequest(ACPPermissionRequest(id: permissionID, toolCall: call, options: [
                ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce),
                ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce),
            ], cwd: summary.cwd)))
        }
        running = Task { [weak self] in
            guard let self else { return }
            do {
                if asksQuestion {
                    let answer = await withCheckedContinuation { self.questionWaiter = $0 }
                    try Task.checkCancellation()
                    let cellular = answer.flatMap { $0.selections["default"]?.optionIDs.first } ?? "webrtc"
                    try await self.stream(MockScript.finalAnswer(cellular: cellular), messageID: "m-waiting-final")
                } else {
                    let choice = await withCheckedContinuation { self.permissionWaiter = $0 }
                    try Task.checkCancellation()
                    let allowed = choice != nil && choice != "deny"
                    self.emit(.update(.toolCallUpdate(ACPToolCallUpdate(
                        toolCallId: "x-waiting", status: allowed ? .completed : .failed,
                        content: [.content(.text(allowed ? "[sync-upstream 7c1d2e9] Merge upstream/main" : "Denied by the person."))]
                    ))))
                    try await self.stream(allowed ? "Merged. The branch builds." : "Left the merge uncommitted.", messageID: "m-waiting-final")
                }
                self.emit(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: Date()))
            } catch {
                self.emit(.turnResult(turnId: turnID, status: .cancelled, errorText: nil, at: Date()))
            }
            self.running = nil
            self.drainQueue()
        }
    }

    private func drainQueue() {
        guard running == nil, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        emit(.dequeued(promptId: next.id))
        startTurn(text: next.text, attachments: next.attachments, promptID: next.id)
    }

    private func pause(_ ms: Int) async throws {
        try await sleep(.milliseconds(ms))
        try Task.checkCancellation()
    }

    private func stream(_ text: String, thought: Bool = false, messageID: String? = nil) async throws {
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            emit(.update(thought ? .agentThoughtChunk(text: chunk) : .agentMessageChunk(text: chunk, messageId: messageID)))
            index = end
            try await sleep(chunkDelay)
            try Task.checkCancellation()
        }
    }

    private func tool(_ call: ACPToolCall, runFor ms: Int, finish: ACPToolCallUpdate) async throws {
        emit(.update(.toolCall(call)))
        try await pause(ms)
        emit(.update(.toolCallUpdate(finish)))
    }

    private func shortTurn(prompt: String) async throws {
        try await pause(500)
        try await stream("Looking at that now.", thought: true)
        // A read and a command: one "Read a file, ran a command" group to open (verify/disclosure.md).
        let readID = UUID().uuidString
        try await tool(
            ACPToolCall(id: readID, title: "Read README.md", kind: .read, locations: [.init(path: "README.md")]),
            runFor: 300, finish: ACPToolCallUpdate(toolCallId: readID, status: .completed,
                                                   content: [.content(.text("# cmux\n\nA terminal for coding agents.\n\n- Workspaces\n- Agent chat\n- Feed"))])
        )
        let statusID = UUID().uuidString
        try await tool(
            ACPToolCall(id: statusID, title: "git status", kind: .execute,
                        rawInput: .object(["command": .string("git status --short")])),
            runFor: 300, finish: ACPToolCallUpdate(toolCallId: statusID, status: .completed,
                                                   content: [.content(.text(" M Sources/Transport/LinkDialer.swift\n?? docs/dialer-notes.md"))],
                                                   rawOutput: .object(["exit_code": .number(0)]))
        )
        try await stream(MockScript.shortAnswer(for: prompt), messageID: UUID().uuidString)
    }

    private func richTurn() async throws {
        let S = MockScript.self
        try await pause(700)
        try await stream(S.thinking, thought: true)
        // Grouped exploration.
        let reads = [
            ("r1", "cmux-next-ios/rust/cmux-mobile-link/src/lib.rs"), ("r2", "cmux-next-ios/rust/cmux-mobile-link/src/dial.rs"),
            ("r3", "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTransport/MacLink.swift"),
        ]
        for (id, path) in reads {
            try await tool(
                ACPToolCall(id: id, title: "Read \((path as NSString).lastPathComponent)", kind: .read, locations: [.init(path: path)]),
                runFor: 260,
                finish: ACPToolCallUpdate(toolCallId: id, status: .completed, content: [.content(.text("// \(path)\n" + S.readSnippet))])
            )
        }
        try await tool(
            ACPToolCall(id: "s1", title: "Search TransportKind", kind: .search, rawInput: .object(["pattern": .string("TransportKind")])),
            runFor: 380,
            finish: ACPToolCallUpdate(toolCallId: "s1", status: .completed, content: [.content(.text(S.searchOutput))])
        )
        try await stream(S.planIntro, messageID: "m-intro")
        var plan = S.plan
        emit(.update(.plan(plan)))
        try await pause(400)
        plan[0].status = .inProgress
        emit(.update(.plan(plan)))
        // Edits.
        try await tool(
            ACPToolCall(id: "e1", title: "Write TransportKind.swift", kind: .edit, status: .inProgress,
                        locations: [.init(path: S.kindPath)]),
            runFor: 600,
            finish: ACPToolCallUpdate(toolCallId: "e1", status: .completed, content: [.diff(path: S.kindPath, oldText: nil, newText: S.kindNew)])
        )
        plan[0].status = .completed
        plan[1].status = .inProgress
        emit(.update(.plan(plan)))
        try await tool(
            ACPToolCall(id: "e2", title: "Edit LinkDialer.swift", kind: .edit, status: .inProgress, locations: [.init(path: S.dialerPath)]),
            runFor: 700,
            finish: ACPToolCallUpdate(toolCallId: "e2", status: .completed, content: [.diff(path: S.dialerPath, oldText: S.dialerOld, newText: S.dialerNew)])
        )
        plan[1].status = .completed
        plan[2].status = .inProgress
        emit(.update(.plan(plan)))
        // Swift tests run (no permission needed).
        try await tool(
            ACPToolCall(id: "x1", title: "Run swift test", kind: .execute,
                        rawInput: .object(["command": .array([.string("bash"), .string("-lc"), .string("swift test --filter LinkDialerTests")])])),
            runFor: 1400,
            finish: ACPToolCallUpdate(toolCallId: "x1", status: .completed, content: [.content(.text(S.swiftTestOutput))],
                                      rawOutput: .object(["exit_code": .number(0)]))
        )
        // Permission for the Rust tests.
        let permissionID = "perm-cargo"
        pendingPermissionID = permissionID
        let cargo = ACPToolCall(id: "x2", title: "cargo test -p cmux-mobile-link", kind: .execute, status: .pending,
                                rawInput: .object(["command": .string("cargo test -p cmux-mobile-link -- --nocapture")]))
        emit(.update(.toolCall(cargo)))
        emit(.permissionRequest(ACPPermissionRequest(id: permissionID, toolCall: cargo, options: [
            ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce),
            ACPPermissionOption(id: "always", name: "Always allow cargo test in this workspace", kind: .allowAlways),
            ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce),
        ], cwd: "~/Development/cmux")))
        let choice = await withCheckedContinuation { self.permissionWaiter = $0 }
        try Task.checkCancellation()
        let allowed = choice != nil && choice != "deny"
        if let choice, choice != "deny" {
            emit(.update(.toolCallUpdate(ACPToolCallUpdate(toolCallId: "x2", status: .inProgress))))
            try await pause(1500)
            emit(.update(.toolCallUpdate(ACPToolCallUpdate(toolCallId: "x2", status: .completed, content: [.content(.text(S.cargoOutput))],
                                                           rawOutput: .object(["exit_code": .number(0)])))))
        } else {
            emit(.update(.toolCallUpdate(ACPToolCallUpdate(toolCallId: "x2", status: .failed, content: [.content(.text("Denied by the person."))]))))
        }
        plan[2].status = .completed
        plan[3].status = .inProgress
        emit(.update(.plan(plan)))
        // AskUserQuestion with two items.
        try await stream(allowed ? S.beforeQuestion : S.beforeQuestionDenied, messageID: "m-q")
        let question = S.question(session: summary.id)
        pendingQuestionID = question.id
        emit(.question(question))
        let answer = await withCheckedContinuation { self.questionWaiter = $0 }
        try Task.checkCancellation()
        let cellular = answer.flatMap { $0.selections["default"]?.optionIDs.first } ?? "webrtc"
        try await tool(
            ACPToolCall(id: "e3", title: "Edit ConnectionSettings.swift", kind: .edit, status: .inProgress, locations: [.init(path: S.settingsPath)]),
            runFor: 700,
            finish: ACPToolCallUpdate(toolCallId: "e3", status: .completed,
                                      content: [.diff(path: S.settingsPath, oldText: S.settingsOld, newText: S.settingsNew(cellular: cellular))])
        )
        plan[3].status = .completed
        emit(.update(.plan(plan)))
        try await pause(300)
        try await stream(S.finalAnswer(cellular: cellular), messageID: "m-final")
    }
}
#endif
