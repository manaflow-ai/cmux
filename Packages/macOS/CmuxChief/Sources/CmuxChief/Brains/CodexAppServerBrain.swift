public import CmuxHomeCore
public import Foundation

/// A ``ChiefBrain`` that drives Codex through `codex app-server`.
///
/// Each conversation gets one app-server process (JSON-RPC over stdio) and
/// one thread on it: `initialize`, then `thread/start` (or `thread/resume`
/// of the conversation's thread) with the Chief's system prompt as developer
/// instructions, then one `turn/start` per user turn. Stop sends
/// `turn/interrupt`. Threads run with approval policy `untrusted`, so Codex
/// asks before any command it does not know is safe; ``ChiefToolPolicy``
/// answers `cmux` and read-only commands itself and turns the rest, and
/// every file change, into approval cards.
public actor CodexAppServerBrain: ChiefBrain {
    /// How the brain launches Codex.
    public struct Configuration: Sendable, Equatable {
        /// The model id for `thread/start` and `turn/start`.
        public var model: String
        /// The reasoning effort for `turn/start`, nil for the model's default.
        public var effort: String?
        /// Whether Codex may bypass approval prompts and its sandbox guardrails. Off by default.
        public var dangerouslySkipPermissions: Bool
        /// An explicit `codex` executable; nil looks it up on `PATH`.
        public var executableOverride: URL?

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - model: The model id.
        ///   - effort: The reasoning effort, nil for the default.
        ///   - dangerouslySkipPermissions: Whether to bypass approval prompts and sandbox guardrails.
        ///   - executableOverride: An explicit `codex` path.
        public init(model: String, effort: String? = nil, dangerouslySkipPermissions: Bool = false,
                    executableOverride: URL? = nil) {
            self.model = model
            self.effort = effort
            self.dangerouslySkipPermissions = dangerouslySkipPermissions
            self.executableOverride = executableOverride
        }
    }

    private let configuration: Configuration
    private let allowRules: ChiefAllowRules?
    private var conversations: [ConversationID: CodexConversation] = [:]
    /// Turns `run` handed out that have not reached their conversation yet.
    private let pendingTurns = ChiefPendingTurns()

    /// Creates a brain.
    ///
    /// - Parameter configuration: How to launch Codex.
    public init(configuration: Configuration, allowRules: ChiefAllowRules? = nil) {
        self.configuration = configuration
        self.allowRules = allowRules
    }

    nonisolated public func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        let token = UUID()
        let conversation = request.conversation
        let pendingTurns = pendingTurns
        // Registered before the stream is returned, so a Stop that beats the start task still finds it.
        pendingTurns.register(token, conversation: conversation)
        continuation.onTermination = { [weak self] _ in
            pendingTurns.stop(token)
            Task { await self?.existing(conversation)?.detach(token) }
        }
        Task { await self.startTurn(request, token: token, continuation: continuation) }
        return stream
    }

    public func respond(toApproval id: String, choice: String, conversation: ConversationID) async {
        await conversations[conversation]?.respond(toApproval: id, allow: ChiefToolPolicy.isAllow(choice))
    }

    public func interrupt(conversation: ConversationID) async {
        pendingTurns.stop(conversation: conversation)
        await conversations[conversation]?.interrupt()
    }

    public func shutdown() async {
        let all = Array(conversations.values)
        conversations = [:]
        for conversation in all { await conversation.shutdown() }
    }

    private func existing(_ id: ConversationID) -> CodexConversation? {
        conversations[id]
    }

    private func startTurn(_ request: ChiefTurnRequest, token: UUID,
                           continuation: AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation) async {
        let session: CodexConversation
        if let existing = conversations[request.conversation] {
            session = existing
        } else {
            session = CodexConversation(configuration: configuration, allowRules: allowRules)
            conversations[request.conversation] = session
        }
        await session.start(request, token: token, continuation: continuation, pending: pendingTurns)
    }

    /// How the driver answers an approval request.
    enum ApprovalDecision: Equatable {
        case allow, deny, ask
    }

    /// The answer to an approval for `command` (nil for file changes): deny
    /// without a running turn (nobody can answer, and a stopped turn must not
    /// run more), allow what ``ChiefToolPolicy`` allows, ask about the rest.
    static func approvalDecision(
        command: String?,
        turnRunning: Bool,
        allowRules: ChiefAllowRules? = nil
    ) -> ApprovalDecision {
        guard turnRunning else { return .deny }
        if let command, ChiefToolPolicy.autoAllowsCommand(command, allowRules: allowRules) { return .allow }
        return .ask
    }

    /// The `thread/start` or `thread/resume` params.
    static func threadParams(_ configuration: Configuration, request: ChiefTurnRequest, resume: String?) -> ChiefJSON {
        var params: [String: ChiefJSON] = [
            "cwd": .string(request.workingDirectory.path),
            "model": .string(configuration.model),
            "approvalPolicy": configuration.dangerouslySkipPermissions ? "never" : "untrusted",
            "sandbox": configuration.dangerouslySkipPermissions ? "danger-full-access" : "workspace-write",
        ]
        if !request.systemPrompt.isEmpty { params["developerInstructions"] = .string(request.systemPrompt) }
        if let resume { params["threadId"] = .string(resume) }
        return .object(params)
    }

    /// The `turn/start` params: the text, then each image as a local file.
    static func turnParams(_ configuration: Configuration, request: ChiefTurnRequest, thread: String) -> ChiefJSON {
        var text = request.userText
        if let reply = request.replyContext, !reply.isEmpty {
            text = "(Replying to: \(ChiefToolPolicy.truncate(reply, to: 2000)))\n\n" + text
        }
        var input: [ChiefJSON] = [["type": "text", "text": .string(text)]]
        for path in request.attachmentPaths {
            input.append(["type": "localImage", "path": .string(path.path)])
        }
        var params: [String: ChiefJSON] = [
            "threadId": .string(thread),
            "input": .array(input),
            "model": .string(configuration.model),
        ]
        if let effort = configuration.effort, !effort.isEmpty { params["effort"] = .string(effort) }
        return .object(params)
    }
}

/// One conversation's app-server process, thread and running turn.
actor CodexConversation {
    private typealias Continuation = AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation

    private let configuration: CodexAppServerBrain.Configuration
    private let allowRules: ChiefAllowRules?
    private var process: ChiefLineProcess?
    private var generation = 0
    private var parser = CodexAppServerParser()
    private var continuation: Continuation?
    private var token: UUID?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<ChiefJSON, any Error>] = [:]
    private var approvals: [String: (requestID: ChiefJSON, kind: CodexApprovalKind)] = [:]
    private var brokenThreads: Set<String> = []
    private var lastThread: String?

    init(configuration: CodexAppServerBrain.Configuration, allowRules: ChiefAllowRules? = nil) {
        self.configuration = configuration
        self.allowRules = allowRules
    }

    func start(_ request: ChiefTurnRequest, token: UUID, continuation: AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation,
               pending: ChiefPendingTurns) async {
        // Claimed on this actor before any suspension, so an `interrupt()`
        // queued after a Stop always sees the turn.
        guard pending.claim(token) else {
            continuation.finish()
            return
        }
        if self.continuation != nil { interrupt() }
        self.continuation = continuation
        self.token = token
        do {
            try await ensureProcess(request)
            let thread = try await ensureThread(request)
            guard self.token == token else { return }
            continuation.yield(.session(thread))
            parser.beginTurn()
            let result = try await call("turn/start", CodexAppServerBrain.turnParams(configuration, request: request, thread: thread))
            guard let turn = result["turn"]?["id"]?.string else { return }
            if self.token == token {
                parser.setTurnID(turn)
            } else {
                // Stopped before Codex named the turn: interrupt it now.
                parser.stop(turn: turn)
                sendInterrupt(thread: thread, turn: turn)
            }
        } catch {
            guard self.token == token else { return }
            end(.failed(String(describing: error)))
        }
    }

    private func ensureProcess(_ request: ChiefTurnRequest) async throws {
        if process != nil { return }
        let environment = ChiefExecutableResolver.environment(request.environment,
                                                              overrides: ["CMUX_CODEX_HOOKS_DISABLED": "1"])
        guard let executable = ChiefExecutableResolver.resolve("codex", override: configuration.executableOverride,
                                                               environment: environment) else {
            throw ChiefBrainError.missingExecutable("codex")
        }
        let child = try ChiefLineProcess(executable: executable, arguments: ["app-server"], environment: environment,
                                         workingDirectory: request.workingDirectory)
        generation += 1
        let mine = generation
        process = child
        parser = CodexAppServerParser()
        let lines = child.lines
        Task { [weak self] in
            for await line in lines { await self?.handle(line, generation: mine) }
            await self?.processEnded(generation: mine)
        }
        let info: ChiefJSON = ["name": "cmux-chief", "title": "cmux", "version": "1"]
        _ = try await call("initialize", ["clientInfo": info])
        write(CodexAppServerParser.notification(method: "initialized"))
    }

    /// The conversation's thread: the current one, a resumed one, or a new one.
    private func ensureThread(_ request: ChiefTurnRequest) async throws -> String {
        if let thread = parser.threadID { return thread }
        if let resume = lastThread ?? request.resumeSession, !brokenThreads.contains(resume) {
            do {
                let result = try await call("thread/resume", CodexAppServerBrain.threadParams(configuration, request: request, resume: resume))
                let thread = result["thread"]?["id"]?.string ?? resume
                parser.threadID = thread
                lastThread = thread
                return thread
            } catch ChiefBrainError.protocolError(_) where process != nil {
                // Codex answered with an error: the thread is gone; start a new one.
                brokenThreads.insert(resume)
            }
        }
        let result = try await call("thread/start", CodexAppServerBrain.threadParams(configuration, request: request, resume: nil))
        guard let thread = result["thread"]?["id"]?.string else {
            throw ChiefBrainError.protocolError(ChiefText.codexNoThread)
        }
        parser.threadID = thread
        lastThread = thread
        return thread
    }

    private func call(_ method: String, _ params: ChiefJSON) async throws -> ChiefJSON {
        guard let process else { throw ChiefBrainError.protocolError(ChiefText.codexNotRunning) }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { waiter in
            pending[id] = waiter
            // Queued, not written: a later EPIPE means the process died, and
            // `processEnded` fails every pending call.
            if !process.write(CodexAppServerParser.request(id: id, method: method, params: params).line) {
                pending.removeValue(forKey: id)?.resume(throwing: ChiefBrainError.protocolError(ChiefText.codexStopped(before: method)))
            }
        }
    }

    private func handle(_ line: Data, generation: Int) {
        guard generation == self.generation else { return }
        for output in parser.consume(line) {
            switch output {
            case .event(let event):
                switch event {
                case .finished, .failed: end(event)
                default: continuation?.yield(event)
                }
            case .response(let id, let result, let error):
                guard let waiter = pending.removeValue(forKey: id) else { continue }
                if let error {
                    waiter.resume(throwing: ChiefBrainError.protocolError(error))
                } else {
                    waiter.resume(returning: result ?? .null)
                }
            case .approval(let requestID, let kind, let command, let prompt):
                let decision = CodexAppServerBrain.approvalDecision(
                    command: command,
                    turnRunning: continuation != nil,
                    allowRules: allowRules
                )
                if decision != .ask {
                    write(CodexAppServerParser.approvalResponse(requestID: requestID, kind: kind, allow: decision == .allow))
                } else {
                    let id = "codex-" + requestID.compactText
                    approvals[id] = (requestID, kind)
                    continuation?.yield(.approvalRequested(id: id, prompt: prompt,
                                                           options: ChiefToolPolicy.approvalOptions(command: command)))
                }
            case .unsupportedRequest(let requestID, let method):
                write(CodexAppServerParser.unsupportedResponse(requestID: requestID, method: method))
            }
        }
    }

    private func processEnded(generation: Int) {
        guard generation == self.generation, let child = process else { return }
        process = nil
        approvals = [:]
        let detail = child.stderrText
        let message = detail.isEmpty ? ChiefText.codexExitedUnexpectedly : ChiefText.codexExited(ChiefToolPolicy.truncate(detail, to: 600))
        let waiters = pending
        pending = [:]
        for waiter in waiters.values { waiter.resume(throwing: ChiefBrainError.protocolError(message)) }
        // The thread lives on in Codex's store; the next process resumes `lastThread`.
        parser = CodexAppServerParser()
        if continuation != nil { end(.failed(message)) }
    }

    func respond(toApproval id: String, allow: Bool) {
        guard let approval = approvals.removeValue(forKey: id) else { return }
        write(CodexAppServerParser.approvalResponse(requestID: approval.requestID, kind: approval.kind, allow: allow))
    }

    /// Stops the running turn: `turn/interrupt`, declines open approvals and
    /// ends the stream.
    func interrupt() {
        guard continuation != nil else { return }
        // Without a turn id yet, `start` interrupts once `turn/start` answers.
        if let thread = parser.threadID, let turn = parser.turnID { sendInterrupt(thread: thread, turn: turn) }
        for approval in approvals.values {
            write(CodexAppServerParser.approvalResponse(requestID: approval.requestID, kind: approval.kind, allow: false))
        }
        approvals = [:]
        parser.abandonTurn()
        end(nil)
    }

    private func sendInterrupt(thread: String, turn: String) {
        nextID += 1
        // The answer is not awaited; a response to an unknown id is ignored.
        write(CodexAppServerParser.request(id: nextID, method: "turn/interrupt",
                                           params: ["threadId": .string(thread), "turnId": .string(turn)]))
    }

    /// The consumer stopped reading turn `token` (cancelled); stop it if it still runs.
    func detach(_ token: UUID) {
        guard self.token == token else { return }
        interrupt()
    }

    func shutdown() {
        end(nil)
        approvals = [:]
        generation += 1
        process?.terminate()
        process = nil
        let waiters = pending
        pending = [:]
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
    }

    private func write(_ json: ChiefJSON) {
        process?.write(json.line)
    }

    private func end(_ event: ChiefTurnEvent?) {
        let open = continuation
        continuation = nil
        token = nil
        if case .failed(let message)? = event {
            // An unknown model reads as one, with a pointer to Chief Settings.
            open?.yield(.failed(ChiefHarness.codex.failureMessage(message, model: configuration.model)))
        } else if let event {
            open?.yield(event)
        }
        open?.finish()
    }
}
